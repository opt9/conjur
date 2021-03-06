class Resource < Sequel::Model
  include HasId
  
  unrestrict_primary_key
  
  one_to_many :permissions, reciprocal: :resource
  one_to_many :annotations, reciprocal: :resource
  one_to_many :secrets,     reciprocal: :resource, order: :version
  one_to_many :policy_versions, reciprocal: :resource, order: :version
  one_to_many :host_factory_tokens, reciprocal: :resource
  many_to_one :owner, class: :Role
  
  alias id resource_id
  
  def kind
    id.split(":", 3)[1]
  end
  
  def identifier
    id.split(":", 3)[2]
  end
  
  def as_json options = {}
    super(options).tap do |response|
      response["id"] = response.delete("resource_id")
      %w(owner policy).each do |field|
        write_id_to_json response, field
      end
      response["permissions"] = permissions.as_json.map {|h| h.except 'resource'}
      response["annotations"] = self.annotations.as_json.map {|h| h.except 'resource'}

      if kind == "variable"
        response["secrets"] = self.secrets.as_json.map {|h| h.except 'resource'}
      end
      if kind == "policy"
        response["policy_versions"] = self.policy_versions.as_json.map {|h| h.except 'resource'}
      end
      if kind == "host_factory"
        response["tokens"] = self.host_factory_tokens.as_json.map {|h| h.except 'resource'}
        response["layers"] = self.role.layers.map(&:role_id)
      end
    end
  end

  class << self
    def make_full_id id, account
      Role.make_full_id id, account
    end
  end

  def extended_associations
    [].tap do |result|
      result << "secrets" if kind == "variable"
      result << "policy_versions" if kind == "policy"
    end
  end
  
  dataset_module do
    # Filter out records based on:
    # @param kind [String] - chooses just resources of this kind
    # @param owner [Role] - owned by this role or one of its ancestors
    # @param offset [Numeric] - an offset into the list of returned results
    # @param limit [Numeric] - a maximum number of results to return
    # @param search [String] - a search term in the resource id
    def search account, kind: nil, owner: nil, offset: nil, limit: nil, search: nil
      scope = self
      
      # Search only the user's account.
      # This can be removed once resource visibility rules are added.
      scope = scope.where("account(resource_id) = ?", account)
      
      # Filter by kind.
      scope = scope.where("kind(resource_id) = ?", kind) if kind
      
      # Filter by owner
      if owner
        owners = Resource.from(::Sequel.function(:all_roles, owner.id)).select(:role_id)
        scope = scope.where owner_id: owners
      end

      # Filter by string search
      scope = scope.textsearch(search) if search

      if offset || limit
        scope = scope.order(:resource_id).limit(
          (limit || 10).to_i,
          (offset || 0).to_i
        )
      end

      scope
    end

    def textsearch input
      # If I use 3 literal spaces, it gets send to PG as one space.
      query = Sequel.function(:plainto_tsquery, 'english',
                              Sequel.function(:translate, input.to_s, './-', '   '))

      # Default weights for ts_rank_cd are {0.1, 0.2, 0.4, 1.0} for DCBA resp.
      # Sounds just about right. A are name and id, B is rest of annotations, C is kind.
      rank = Sequel.function(:ts_rank_cd, :textsearch, query)

      natural_join(:resources_textsearch).
        where("? @@ textsearch", query).
        order(Sequel.desc(rank))
    end
  end

  def role
    Role[id] or raise "Role not found for #{id}"
  end

  # Permission grants are performed by the policy loader, but not exposed through the API.
  def permit privilege, role, options = {}
    options[:privilege] = privilege
    options[:role] = role
    add_permission options
  end
  
  # Truncate secrets beyond the configured limit.
  def enforce_secrets_version_limit limit = secrets_version_limit
    # The Sequel-foo for this escapes me.
    Sequel::Model.db[<<-SQL, resource_id, limit, resource_id].delete
    WITH 
      "ordered_secrets" AS 
        (SELECT * FROM "secrets" WHERE ("resource_id" = ?) ORDER BY "version" DESC LIMIT ?), 
      "delete_secrets" AS 
        (SELECT * FROM "secrets" LEFT JOIN "ordered_secrets" USING ("resource_id", "version") WHERE (("ordered_secrets"."resource_id" IS NULL) AND ("resource_id" = ?))) 
    DELETE FROM "secrets"
    USING "delete_secrets"
    WHERE "secrets"."resource_id" = "delete_secrets"."resource_id" AND
      "secrets"."version" = "delete_secrets"."version"
    SQL
  end
end
