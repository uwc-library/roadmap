# frozen_string_literal: true

module Api

  module V1

    class PlansController < BaseApiController

      respond_to :json

      # GET /api/v1/plans/:id
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/PerceivedComplexity, Metrics/MethodLength
      def show
        plans = Plan.where(id: params[:id]).limit(1)

        if plans.any?
          if client.is_a?(User)
            # If the specified plan does not belong to the org or the owner's org
            if plans.first.org_id != client.org_id &&
               plans.first.owner&.org_id != client.org_id

              # Kaminari pagination requires an ActiveRecord resultset :/
              plans = Plan.where(id: nil).limit(1)
            end

          elsif client.is_a?(ApiClient) && plans.first.api_client_id != client.id &&
                !plans.first.publicly_visible?
            # Kaminari pagination requires an ActiveRecord resultset :/
            plans = Plan.where(id: nil).limit(1)
          end

          if plans.present? && plans.any?
            @items = paginate_response(results: plans)
            render "/api/v1/plans/index", status: :ok
          else
            render_error(errors: [_("Plan not found")], status: :not_found)
          end
        else
          render_error(errors: [_("Plan not found")], status: :not_found)
        end
      end

      # POST /api/v1/plans
      def create
        dmp = @json.with_indifferent_access.fetch(:items, []).first.fetch(:dmp, {})

        # If a dmp_id was passed in try to find it
        if dmp[:dmp_id].present? && dmp[:dmp_id][:identifier].present?
          scheme = IdentifierScheme.by_name(dmp[:dmp_id][:type]).first
          dmp_id = Identifier.where(value: dmp[:dmp_id][:identifier],
                                    identifier_scheme: scheme)
        end

        # Skip if this is an existing DMP
        if dmp_id.present?
          render_error(errors: _("Plan already exists. Send an update instead."),
                       status: :bad_request)
        else
          # Time prior to JSON parser service call which will create the plan so
          # we can stop the creation of duplicate plans below
          now = (Time.now - 1.minute)
          plan = Api::V1::Deserialization::Plan.deserialize!(json: dmp)

          if plan.present?
            if plan.created_at.utc < now.utc
              render_error(errors: _("Plan already exists. Send an update instead."),
                           status: :bad_request)

            else
              # If the plan was generated by an ApiClient then associate them
              # rubocop:disable Metrics/BlockNesting
              plan.update(api_client_id: client.id) if client.is_a?(ApiClient)
              # rubocop:enable Metrics/BlockNesting
              assign_roles(plan: plan)

              # Kaminari Pagination requires an ActiveRecord result set :/
              @items = paginate_response(results: Plan.where(id: plan.id))
              render "/api/v1/plans/index", status: :created
            end
          else
            render_error(errors: [_("Invalid JSON")], status: :bad_request)
          end
        end
      rescue JSON::ParserError
        render_error(errors: [_("Invalid JSON")], status: :bad_request)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/PerceivedComplexity, Metrics/MethodLength

      # GET /api/v1/plans
      def index
        # ALL can view: public
        # ApiClient can view: anything from the API client
        # User (non-admin) can view: any personal or organisationally_visible
        # User (admin) can view: all from users of their organisation
        plans = Api::V1::PlansPolicy::Scope.new(client, Plan).resolve
        if plans.present? && plans.any?
          @items = paginate_response(results: plans)
          @minimal = true
          render "api/v1/plans/index", status: :ok
        else
          render_error(errors: [_("No Plans found")], status: :not_found)
        end
      end

      private

      def dmp_params
        params.require(:dmp).permit(plan_permitted_params).to_h
      end

      # rubocop:disable Metrics/MethodLength
      def assign_roles(plan:)
        # Attach all of the authors and then invite them if necessary
        owner = nil
        plan.contributors.data_curation.each do |contributor|
          user = contributor_to_user(contributor: contributor)
          next unless user.present?

          # Attach the role
          role = Role.new(user: user, plan: plan)
          role.creator = true if contributor.data_curation?
          # We only want one owner/creator so jusst use the 1st contributor
          # which should be the contact in the JSON input
          owner = contributor if contributor.data_curation?
          role.administrator = true if contributor.data_curation? &&
                                       !contributor.present?
          role.save
        end
      end
      # rubocop:enable Metrics/MethodLength

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def contributor_to_user(contributor:)
        identifiers = contributor.identifiers.map do |id|
          { name: id.identifier_scheme&.name, value: id.value }
        end
        user = User.from_identifiers(array: identifiers) if identifiers.any?
        user = User.find_by(email: contributor.email) unless user.present?
        return user if user.present?

        # If the user was not found, invite them and attach any know identifiers
        names = contributor.name&.split || [""]
        firstname = names.length > 1 ? names.first : nil
        surname = names.length > 1 ? names.last : names.first
        user = User.invite!({ email: contributor.email,
                              firstname: firstname,
                              surname: surname,
                              org: contributor.org }, client)

        contributor.identifiers.each do |id|
          user.identifiers << Identifier.new(
            identifier_scheme: id.identifier_scheme, value: id.value
          )
        end
        user
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    end

  end

end
