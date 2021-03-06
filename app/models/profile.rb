=begin
    Copyright 2013 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

class Profile < ActiveRecord::Base
    include Extensions::Notifier

    has_and_belongs_to_many :users
    belongs_to :owner,  class_name: 'User', foreign_key: :owner_id

    DESCRIPTIONS_FILE = "#{Rails.root}/config/profile/attributes.yml"

    validates_presence_of   :name
    validates_uniqueness_of :name, scope: :owner_id, case_sensitive: false

    validates_presence_of   :description

    validate :validate_description
    validate :validate_plugins
    validate :validate_plugin_options
    validate :validate_redundant
    validate :validate_cookies
    validate :validate_custom_headers
    validate :validate_login_check

    # #modules= will ignore any any modules which have not specifically been
    # authorized so this is not strictly required.
    validate :validate_modules

    serialize :cookies,         Hash
    serialize :custom_headers,  Hash
    serialize :exclude,         Array
    serialize :exclude_pages,   Array
    serialize :include,         Array
    serialize :exclude_cookies, Array
    serialize :exclude_vectors, Array
    serialize :extend_paths,    Array
    serialize :restrict_paths,  Array
    serialize :modules,         Array
    serialize :plugins,         Hash
    serialize :redundant,       Hash

    before_save :add_owner_to_subscribers

    RPC_OPTS = [ :audit_cookies, :audit_cookies_extensively, :audit_forms,
                 :audit_headers, :audit_links, :authed_by, :auto_redundant,
                 :cookies, :custom_headers, :depth_limit, :exclude,
                 :exclude_binaries, :exclude_cookies, :exclude_vectors,
                 :extend_paths, :follow_subdomains, :fuzz_methods, :http_req_limit,
                 :include, :link_count_limit, :login_check_pattern, :login_check_url,
                 :max_slaves, :min_pages_per_instance, :modules, :plugins, :proxy_host,
                 :proxy_password, :proxy_port, :proxy_type, :proxy_username,
                 :redirect_limit, :redundant, :restrict_paths, :user_agent,
                 :http_timeout, :https_only, :exclude_pages ]

    scope :global, -> { where global: true }

    def self.describe_notification( action )
        case action
            when :destroy
                'was deleted'
            when :create
                'created'
            when :update
                'was updated'
            when :share
                'was shared with you'
            when :make_default
                'was set as the system default'
            else
                action.to_s
        end
    end

    def self.default
        self.where( default: true ).first
    end

    def self.unmake_default
        update_all default: false
    end

    def self.recent( limit = 5 )
        order( 'id desc' ).limit( limit )
    end

    def self.light
        select( [:id, :name] )
    end

    def subscribers
        users | [owner]
    end

    def family
        [self]
    end

    def to_s
        name
    end

    def make_default
        self.class.unmake_default
        self.default = true
        self.save
    end

    def default?
        !!self.default
    end

    def to_rpc_options
        opts = {}
        attributes.each do |k, v|
            next if !RPC_OPTS.include?( k.to_sym ) || v.nil? ||
                (v.respond_to?( :empty? ) ? v.empty? : false)
            opts[k.to_sym] = v
        end
        opts
    end

    def modules
        # Only allow authorized modules.
        super & Settings.profile_allowed_modules
    end

    def plugins
        # Only allow authorized plugins.
        super.select { |k, _| Settings.profile_allowed_plugins.include? k }
    end

    def html_description
        ApplicationHelper.m description
    end

    def html_description_excerpt( *args )
        ApplicationHelper.truncate_html *[html_description, args].flatten
    end

    def redundant=( string_or_hash )
        super self.class.string_list_to_hash( string_or_hash, ':' )
    end

    def exclude=( string_or_array )
        super self.class.string_list_to_array( string_or_array )
    end

    def exclude_pages=( string_or_array )
        super self.class.string_list_to_array( string_or_array )
    end

    def include=( string_or_array )
        super self.class.string_list_to_array( string_or_array )
    end

    def restrict_paths=( string_or_array )
        super self.class.string_list_to_array( string_or_array )
    end

    def extend_paths=( string_or_array )
        super self.class.string_list_to_array( string_or_array )
    end

    def exclude_vectors=( string_or_array )
        super self.class.string_list_to_array( string_or_array )
    end

    def exclude_cookies=( string_or_array )
        super self.class.string_list_to_array( string_or_array )
    end

    def cookies=( string_or_hash )
        super self.class.string_list_to_hash( string_or_hash )
    end

    def custom_headers=( string_or_hash )
        super self.class.string_list_to_hash( string_or_hash )
    end

    def modules=( m )
        # Only allow authorized modules.

        if m == :all || m == :default
            return super( ::FrameworkHelper.modules.keys.map( &:to_s ) & Settings.profile_allowed_modules.to_a )
        end

        super m & Settings.profile_allowed_modules.to_a
    end

    def plugins=( p )
        # Only allow authorized plugins.

        if p == :default
            c = ::FrameworkHelper.default_plugins.keys.inject( {} ) { |h, name| h[name] = {}; h }
            return super c
        end

        super p.select { |k, _| Settings.profile_allowed_plugins.include? k }
    end

    def modules_with_info
        modules.inject( {} ) { |h, name| h[name] = ::FrameworkHelper.modules[name]; h }
    end

    def has_modules?
        self.modules.any?
    end

    def has_plugins?
        self.plugins.any?
    end

    def plugins_with_info
        plugins.keys.inject( {} ) { |h, name| h[name] = ::FrameworkHelper.plugins[name]; h }
    end

    def self.string_for( attribute, type = nil )
        @descriptions ||= YAML.load( IO.read( DESCRIPTIONS_FILE ) )

        case description = @descriptions[attribute.to_s]
            when String
                return if type != :description
                description
            when Hash
                description[type.to_s]
        end
    end

    def self.description_for( attribute )
        string_for( attribute, :description )
    end
    def description_for( attribute )
        self.class.description_for( attribute )
    end

    def self.notice_for( attribute )
        string_for( attribute, :notice )
    end
    def notice_for( attribute )
        self.class.notice_for( attribute )
    end

    def self.warning_for( attribute )
        string_for( attribute, :warning )
    end
    def warning_for( attribute )
        self.class.warning_for( attribute )
    end

    def self.string_list_to_array( string_or_array )
        case string_or_array
            when Array
                string_or_array
            else
                string_or_array.to_s.split( /[\n\r]/ ).reject( &:empty? )
        end
    end

    def self.string_list_to_hash( string_or_hash, hash_delimiter = '=' )
        case string_or_hash
            when Hash
                string_or_hash
            else
                Hash[string_or_hash.to_s.split( /[\n\r]/ ).reject( &:empty? ).
                               map{ |rule| rule.split( hash_delimiter, 2 ) }]
        end
    end

    def validate_description
        return if ActionController::Base.helpers.strip_tags( description ) == description
        errors.add :description, 'cannot contain HTML, please use Markdown instead'
    end

    def validate_redundant
        redundant.each do |pattern, counter|
            next if counter.to_i > 0
            errors.add :redundant, "rule '#{pattern}' needs an integer counter greater than 0"
        end
    end

    def validate_cookies
        cookies.each do |name, value|
            errors.add :cookies, "name cannot be blank ('#{name}=#{value}')" if name.empty?
        end
    end

    def validate_custom_headers
        custom_headers.each do |name, value|
            errors.add :custom_headers, "name cannot be blank ('#{name}=#{value}')" if name.empty?
        end
    end

    def validate_login_check
        return if login_check_url.to_s.empty? && login_check_pattern.to_s.empty?
        if (url = Arachni::URI( login_check_url )).to_s.empty? || !url.absolute?
            errors.add :login_check_url, 'not a valid absolute URL'
        end

        errors.add :login_check_pattern, 'cannot be blank' if login_check_pattern.to_s.empty?
    end

    def validate_modules
        available = ::FrameworkHelper.modules.keys.map( &:to_s )
        modules.each do |mod|
            next if available.include? mod.to_s
            errors.add :modules, "'#{mod}' does not exist"
        end
    end

    def validate_plugins
        available = ::FrameworkHelper.plugins.keys.map( &:to_s )
        plugins.keys.each do |plugin|
            next if available.include? plugin.to_s
            errors.add :plugins, "'#{plugin}' does not exist"
        end
    end

    def validate_plugin_options
        available = ::FrameworkHelper.plugins.keys.map( &:to_s )
        ::FrameworkHelper.framework do |f|
            plugins.each do |plugin, options|
                next if !available.include? plugin.to_s

                begin
                    f.plugins.prep_opts( plugin, f.plugins[plugin], options )
                rescue Arachni::Component::Options::Error::Invalid => e
                    errors.add :plugins, e.to_s
                end
            end
        end
    end

    private

    def add_owner_to_subscribers
        self.user_ids |= [owner.id]
        true
    end
end
