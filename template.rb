# frozen_string_literal: true

after_bundle do
  run "bundle add inertia_rails"
  run "bundle add nanoid --skip-install"
  run "bundle add name_of_person --skip-install"
  run "bundle install"

  gsub_file "Gemfile", /^gem ["']turbo-rails["'].*\n/, ""
  gsub_file "Gemfile", /^gem ["']stimulus-rails["'].*\n/, ""

  run "printf 'y\ny\nreact\ny\n' | bin/rails generate inertia:install --skip-example"

  file "config/aws.yml", <<~YAML
    shared: &shared
      smtp_endpoint: ~
      smtp_username: ~
      smtp_password: ~
      authentication: ~

    development:
      <<: *shared

    test:
      <<: *shared

    production:
      smtp_endpoint: "email-smtp.us-east-1.amazonaws.com"
      smtp_username: <%= Rails.application.credentials.dig(:aws, :smtp_username) %>
      smtp_password: <%= Rails.application.credentials.dig(:aws, :smtp_password) %>
      authentication: :login
  YAML

  gsub_file "config/application.rb", "class Application < Rails::Application", <<~RUBY.chomp
    class Application < Rails::Application
      config.aws = config_for(:aws)
      config.active_job.queue_adapter = :solid_queue
      config.solid_queue.connects_to = { database: { writing: :queue } }
      config.solid_cache.connects_to = { database: { writing: :cache } }
  RUBY

  inject_into_file "config/environments/development.rb", <<~RUBY, before: "\nend\n"

    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: "127.0.0.1",
      port: 1025,
      domain: "localhost"
    }
    config.action_mailer.raise_delivery_errors = false
    config.action_mailer.default_url_options = { host: "localhost", port: 3000 }
  RUBY

  inject_into_file "config/environments/production.rb", <<~RUBY, before: "\nend\n"

    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: Rails.configuration.aws.smtp_endpoint,
      user_name: Rails.configuration.aws.smtp_username,
      password: Rails.configuration.aws.smtp_password,
      enable_starttls: true,
      port: 587,
      authentication: Rails.configuration.aws.authentication
    }
  RUBY

  remove_file "config/routes.rb"
  file "config/routes.rb", <<~RUBY
    Rails.application.routes.draw do
      resource :session, only: %i[new create destroy] do
        scope module: :sessions do
          resource :magic_link, only: %i[show create]
        end
      end

      resource :signup, only: %i[new create]
      resource :onboarding, only: %i[new create]
      resource :dashboard, only: :show, controller: "dashboards"

      root "dashboards#show"

      get "up" => "rails/health#show", as: :rails_health_check
    end
  RUBY

  file "app/models/current.rb", <<~RUBY
    class Current < ActiveSupport::CurrentAttributes
      attribute :session, :organization
      delegate :user, to: :session, allow_nil: true
    end
  RUBY

  file "app/models/user.rb", <<~RUBY
    class User < ApplicationRecord
      has_person_name

      has_many :sessions, dependent: :destroy
      has_many :magic_links, dependent: :destroy
      has_many :memberships, class_name: "Organization::Membership", dependent: :destroy
      has_many :organizations, through: :memberships

      normalizes :email_address, with: ->(email) { email.strip.downcase }

      validates :email_address, presence: true, uniqueness: true

      def send_magic_link_later(purpose: :sign_in)
        magic_links.create!(purpose: purpose).tap do |magic_link|
          MagicLinkMailer.sign_in_instructions(magic_link).deliver_later
        end
      end
    end
  RUBY

  file "app/models/signup.rb", <<~RUBY
    class Signup
      include ActiveModel::Model

      attr_accessor :name, :email_address
      attr_reader :user

      validates :name, presence: true
      validates :email_address, presence: true

      def create_user
        if invalid?
          false
        elsif User.exists?(email_address: normalized_email)
          errors.add(:email_address, "is already registered")
          false
        else
          @user = User.create!(name: name, email_address: normalized_email)
          @user.send_magic_link_later(purpose: :sign_up)
          true
        end
      end

      private
        def normalized_email
          email_address.to_s.strip.downcase
        end
    end
  RUBY

  file "app/models/session.rb", <<~RUBY
    class Session < ApplicationRecord
      belongs_to :user
    end
  RUBY

  file "app/models/magic_link.rb", <<~RUBY
    class MagicLink < ApplicationRecord
      include NanoidGenerator

      CODE_LENGTH = 6
      EXPIRATION_TIME = 15.minutes

      belongs_to :user

      enum :purpose, { sign_in: "sign_in", sign_up: "sign_up" }, prefix: :for, default: :sign_in

      scope :active, -> { where(expires_at: Time.current...) }
      scope :stale, -> { where(expires_at: ..Time.current) }

      before_validation :generate_code, on: :create
      before_validation :set_expiration, on: :create

      validates :code, uniqueness: true, presence: true

      class << self
        def consume(code)
          active.find_by(code: code.to_s.strip.downcase)&.tap(&:destroy)
        end

        def cleanup
          stale.delete_all
        end
      end

      private
        def generate_code
          self.code ||= loop do
            candidate = generate_nanoid(size: CODE_LENGTH)
            break candidate unless self.class.exists?(code: candidate)
          end
        end

        def set_expiration
          self.expires_at ||= EXPIRATION_TIME.from_now
        end
    end
  RUBY

  file "app/models/organization.rb", <<~RUBY
    class Organization < ApplicationRecord
      has_many :memberships, class_name: "Organization::Membership", dependent: :destroy
      has_many :users, through: :memberships

      before_validation :assign_slug, on: :create

      validates :name, presence: true
      validates :slug, uniqueness: true

      private
        def assign_slug
          return if slug.present? || name.blank?

          self.slug = "\#{name.parameterize}-\#{SecureRandom.hex(4)}"
        end
    end
  RUBY

  file "app/models/organization/membership.rb", <<~RUBY
    class Organization::Membership < ApplicationRecord
      belongs_to :organization
      belongs_to :user

      enum :role, %w[member admin owner].index_by(&:itself), default: :owner
    end
  RUBY

  file "app/models/concerns/nanoid_generator.rb", <<~RUBY
    module NanoidGenerator
      extend ActiveSupport::Concern

      private
        def generate_nanoid(size: 12)
          Nanoid.generate(size:, alphabet: ("a".."z").to_a + ("0".."9").to_a)
        end
    end
  RUBY

  remove_file "app/controllers/application_controller.rb"
  file "app/controllers/application_controller.rb", <<~RUBY
    class ApplicationController < ActionController::Base
      include Authentication, RequireOrganization
    end
  RUBY

  file "app/controllers/inertia_controller.rb", <<~RUBY
    class InertiaController < ApplicationController
      inertia_share auth: -> {
        {
          user: Current.user&.as_json(only: %i[id first_name last_name email_address], methods: [:name]),
          organization: Current.organization&.as_json(only: %i[id name slug])
        }
      }

      inertia_share flash: -> { flash.to_h.slice("notice", "alert") }
    end
  RUBY

  file "app/controllers/concerns/authentication.rb", <<~RUBY
    module Authentication
      extend ActiveSupport::Concern

      included do
        before_action :require_authentication
        helper_method :authenticated?
      end

      class_methods do
        def allow_unauthenticated_access(**options)
          skip_before_action :require_authentication, **options
        end
      end

      private
        def authenticated?
          resume_session
        end

      def require_authentication
        resume_session || request_authentication
      end

      def resume_session
        if session = find_session_by_cookie
          Current.session = session
        end
      end

      def find_session_by_cookie
        Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
      end

      def request_authentication
        session[:return_to_after_authenticating] = request.url
        redirect_to new_session_path
      end

      def after_authentication_url
        session.delete(:return_to_after_authenticating) || root_url
      end

      def start_new_session_for(user)
        user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |created_session|
          Current.session = created_session
          cookies.signed.permanent[:session_id] = { value: created_session.id, httponly: true, same_site: :lax }
        end
      end

      def terminate_session
        Current.session.destroy
        cookies.delete(:session_id)
      end
    end
  RUBY

  file "app/controllers/concerns/require_organization.rb", <<~RUBY
    module RequireOrganization
      extend ActiveSupport::Concern

      included do
        before_action :set_current_organization, if: :authenticated?
        before_action :require_organization, if: :authenticated?
      end

      class_methods do
        def allow_missing_organization(**options)
          skip_before_action :require_organization, **options
        end
      end

      private
        def set_current_organization
          Current.organization = Current.user&.organizations&.first
        end

        def require_organization
          return if Current.organization

          redirect_to new_onboarding_path, status: :see_other
        end
    end
  RUBY

  file "app/controllers/sessions_controller.rb", <<~RUBY
    class SessionsController < InertiaController
      allow_unauthenticated_access only: %i[new create]
      allow_missing_organization only: :destroy
      rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

      def new
        render inertia: "auth/login"
      end

      def create
        email_address = params.require(:email_address).to_s.strip.downcase
        user = User.find_or_create_by!(email_address:)
        user.send_magic_link_later
        redirect_to session_magic_link_path, notice: "We sent a code to \#{email_address}."
      end

      def destroy
        terminate_session
        redirect_to new_session_path, status: :see_other
      end
    end
  RUBY

  file "app/controllers/signups_controller.rb", <<~RUBY
    class SignupsController < InertiaController
      allow_unauthenticated_access only: %i[new create]
      allow_missing_organization only: %i[new create]

      def new
        render inertia: "auth/signup", props: {
          errors: {},
          email_address: "",
          name: ""
        }
      end

      def create
        signup = Signup.new(signup_params)

        if signup.create_user
          redirect_to session_magic_link_path
        else
          render inertia: "auth/signup", props: {
            errors: signup.errors.to_hash,
            email_address: signup.email_address,
            name: signup.name
          }, status: :unprocessable_entity
        end
      end

      private
        def signup_params
          params.fetch(:signup, {}).permit(:name, :email_address)
        end
    end
  RUBY

  file "app/controllers/sessions/magic_links_controller.rb", <<~RUBY
    class Sessions::MagicLinksController < InertiaController
      allow_unauthenticated_access only: %i[show create]
      allow_missing_organization only: %i[show create]
      rate_limit to: 10, within: 15.minutes, only: :create, with: -> { redirect_to session_magic_link_path, alert: "Wait 15 minutes, then try again." }

      def show
        render inertia: "auth/verify", props: {
          code_length: MagicLink::CODE_LENGTH,
          expiration_minutes: (MagicLink::EXPIRATION_TIME / 60).to_i
        }
      end

      def create
        magic_link = MagicLink.consume(params.require(:code).to_s.strip)

        if magic_link
          start_new_session_for(magic_link.user)
          redirect_to new_onboarding_path
        else
          render inertia: "auth/verify", props: {
            code_length: MagicLink::CODE_LENGTH,
            expiration_minutes: (MagicLink::EXPIRATION_TIME / 60).to_i,
            error: "Invalid or expired code. Please try again."
          }
        end
      end
    end
  RUBY

  file "app/controllers/onboardings_controller.rb", <<~RUBY
    class OnboardingsController < InertiaController
      allow_missing_organization only: %i[new create]

      def new
        return redirect_to(root_path) if Current.organization

        render inertia: "onboarding/organization"
      end

      def create
        return redirect_to(root_path) if Current.organization

        organization = Organization.create!(name: organization_params.fetch(:name))
        Current.user.memberships.create!(organization:, role: :owner)
        Current.organization = organization

        redirect_to dashboard_path
      end

      private
        def organization_params
          params.fetch(:organization, {}).permit(:name)
        end
    end
  RUBY

  file "app/controllers/dashboards_controller.rb", <<~RUBY
    class DashboardsController < InertiaController
      def show
        render inertia: "dashboard/show"
      end
    end
  RUBY

  file "app/mailers/magic_link_mailer.rb", <<~RUBY
    class MagicLinkMailer < ApplicationMailer
      def sign_in_instructions(magic_link)
        @magic_link = magic_link
        @user = @magic_link.user

        mail to: @user.email_address, subject: "Your sign-in code is \#{@magic_link.code}"
      end
    end
  RUBY

  file "app/views/magic_link_mailer/sign_in_instructions.text.erb", <<~ERB
    Hi there,

    Please enter this <%= MagicLink::CODE_LENGTH %>-character verification code on the sign-in page:

    <%= @magic_link.code %>

    This code will work for <%= distance_of_time_in_words(MagicLink::EXPIRATION_TIME) %>.
  ERB

  file "app/views/magic_link_mailer/sign_in_instructions.html.erb", <<~ERB
    <p>Hi there,</p>
    <p>Please enter this <%= MagicLink::CODE_LENGTH %>-character verification code on the sign-in page:</p>
    <p><strong><%= @magic_link.code %></strong></p>
    <p>This code will work for <%= distance_of_time_in_words(MagicLink::EXPIRATION_TIME) %>.</p>
  ERB

  remove_file "app/views/layouts/application.html.erb"
  file "app/views/layouts/application.html.erb", <<~ERB
    <!DOCTYPE html>
    <html>
      <head>
        <title data-inertia><%= content_for(:title) || "Rails B2B" %></title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <%= csrf_meta_tags %>
        <%= csp_meta_tag %>
        <%= stylesheet_link_tag :app %>
        <%= vite_react_refresh_tag %>
        <%= vite_client_tag %>
        <%= vite_typescript_tag "inertia.tsx" %>
        <%= inertia_ssr_head %>
      </head>
      <body>
        <%= yield %>
      </body>
    </html>
  ERB

  file "app/frontend/layouts/auth-layout.tsx", <<~TSX
    import type { ReactNode } from "react"

    type Props = { children: ReactNode }

    export function AuthLayout({ children }: Props) {
      return (
        <div style={{ maxWidth: "640px", margin: "40px auto", fontFamily: "sans-serif" }}>
          <h2>Rails B2B</h2>
          {children}
        </div>
      )
    }
  TSX

  file "app/frontend/layouts/app-layout.tsx", <<~TSX
    import type { ReactNode } from "react"
    import { Link, usePage } from "@inertiajs/react"
    import type { SharedProps } from "../types"

    type Props = { children: ReactNode }

    export function AppLayout({ children }: Props) {
      const { auth } = usePage<SharedProps>().props

      return (
        <div style={{ maxWidth: "840px", margin: "40px auto", fontFamily: "sans-serif" }}>
          <header style={{ display: "flex", justifyContent: "space-between", marginBottom: "20px" }}>
            <strong>{auth.organization?.name || "Dashboard"}</strong>
            <Link href="/session" method="delete" as="button">Sign out</Link>
          </header>
          {children}
        </div>
      )
    }
  TSX

  file "app/frontend/types/index.ts", <<~TS
    export type FlashData = {
      notice?: string
      alert?: string
    }

    export type User = {
      id: number
      first_name: string | null
      last_name: string | null
      email_address: string
      name: string
    }

    export type Organization = {
      id: number
      name: string
      slug: string
    }

    export type SharedProps = {
      auth: { user: User | null; organization: Organization | null }
      flash: FlashData
    }
  TS

  file "app/frontend/pages/auth/login.tsx", <<~TSX
    import { useForm } from "@inertiajs/react"

    export default function LoginPage() {
      const form = useForm({ email_address: "" })

      return (
        <section>
          <h1>Sign in</h1>
          <p>Enter your work email. We will send you a one-time code.</p>

          <form
            onSubmit={(event) => {
              event.preventDefault()
              form.post("/session")
            }}
          >
            <input
              type="email"
              name="email_address"
              required
              autoFocus
              placeholder="you@example.com"
              value={form.data.email_address}
              onChange={(event) => form.setData("email_address", event.target.value)}
            />
            <button type="submit" disabled={form.processing}>
              {form.processing ? "Sending..." : "Send Code"}
            </button>
          </form>
        </section>
      )
    }
  TSX

  file "app/frontend/pages/auth/signup.tsx", <<~TSX
    import { Link, useForm } from "@inertiajs/react"

    type Props = {
      errors?: Record<string, string[]>
      email_address?: string
      name?: string
    }

    export default function SignupPage({ errors = {}, email_address = "", name = "" }: Props) {
      const form = useForm({ email_address, name })

      return (
        <section>
          <h1>Create account</h1>
          <p>
            Already have an account? <Link href="/session/new">Sign in</Link>
          </p>

          <form
            onSubmit={(event) => {
              event.preventDefault()
              form.transform((data) => ({ signup: data }))
              form.post("/signup")
            }}
          >
            <input
              type="text"
              name="name"
              required
              placeholder="Name"
              value={form.data.name}
              onChange={(event) => form.setData("name", event.target.value)}
            />
            {errors.name ? <p>{errors.name.join(", ")}</p> : null}

            <input
              type="email"
              name="email_address"
              required
              placeholder="you@example.com"
              value={form.data.email_address}
              onChange={(event) => form.setData("email_address", event.target.value)}
            />
            {errors.email_address ? <p>{errors.email_address.join(", ")}</p> : null}

            <button type="submit" disabled={form.processing}>
              {form.processing ? "Creating..." : "Create account"}
            </button>
          </form>
        </section>
      )
    }
  TSX

  file "app/frontend/pages/auth/verify.tsx", <<~TSX
    import { useForm } from "@inertiajs/react"

    type Props = {
      code_length: number
      expiration_minutes: number
      error?: string
    }

    export default function VerifyPage({ code_length, expiration_minutes, error }: Props) {
      const form = useForm({ code: "" })

      return (
        <section>
          <h1>Check your email</h1>
          <p>Enter the {code_length}-character code.</p>

          <form
            onSubmit={(event) => {
              event.preventDefault()
              form.post("/session/magic_link")
            }}
          >
            <input
              type="text"
              name="code"
              required
              autoFocus
              maxLength={code_length}
              value={form.data.code}
              onChange={(event) => form.setData("code", event.target.value)}
            />
            <button type="submit" disabled={form.processing || form.data.code.length !== code_length}>
              {form.processing ? "Verifying..." : "Continue"}
            </button>
          </form>

          {error ? <p>{error}</p> : null}
          <p>This code expires in {expiration_minutes} minutes.</p>
        </section>
      )
    }
  TSX

  file "app/frontend/pages/onboarding/organization.tsx", <<~TSX
    import { useForm } from "@inertiajs/react"

    export default function OrganizationOnboardingPage() {
      const form = useForm({ name: "" })

      return (
        <section>
          <h1>Create your organization</h1>
          <form
            onSubmit={(event) => {
              event.preventDefault()
              form.transform((data) => ({ organization: data }))
              form.post("/onboarding")
            }}
          >
            <input
              type="text"
              name="name"
              required
              autoFocus
              placeholder="Acme Inc."
              value={form.data.name}
              onChange={(event) => form.setData("name", event.target.value)}
            />
            <button type="submit" disabled={form.processing}>
              {form.processing ? "Creating..." : "Create Organization"}
            </button>
          </form>
        </section>
      )
    }
  TSX

  file "app/frontend/pages/dashboard/show.tsx", <<~TSX
    import { usePage } from "@inertiajs/react"
    import type { SharedProps } from "../../types"

    export default function DashboardPage() {
      const { auth } = usePage<SharedProps>().props

      return (
        <section>
          <h1>Dashboard</h1>
          <p>Welcome, {auth.user?.name || auth.user?.email_address}.</p>
          <p>Your organization: {auth.organization?.name}.</p>
        </section>
      )
    }
  TSX

  rails_command "generate migration CreateUsers first_name:string last_name:string email_address:string"
  rails_command "generate migration CreateSessions user:references ip_address:string user_agent:string"
  rails_command "generate migration CreateMagicLinks user:references code:string purpose:string expires_at:datetime"
  rails_command "generate migration CreateOrganizations name:string slug:string"
  rails_command "generate migration CreateOrganizationMemberships organization:references user:references role:string"

  file "test/models/magic_link_test.rb", <<~RUBY
    require "test_helper"

    class MagicLinkTest < ActiveSupport::TestCase
      test "consume returns active link and destroys it" do
        user = User.create!(email_address: "owner@example.com")
        magic_link = user.magic_links.create!(purpose: :sign_in)

        consumed = MagicLink.consume(magic_link.code)

        assert_equal magic_link.id, consumed.id
        assert_not MagicLink.exists?(magic_link.id)
      end

      test "consume returns nil for stale link" do
        user = User.create!(email_address: "owner@example.com")
        magic_link = user.magic_links.create!(purpose: :sign_in, expires_at: 1.minute.ago)

        assert_nil MagicLink.consume(magic_link.code)
      end
    end
  RUBY

  file "test/integration/authentication_flow_test.rb", <<~RUBY
    require "test_helper"

    class AuthenticationFlowTest < ActionDispatch::IntegrationTest
      test "dashboard requires authentication" do
        get "/dashboard"
        assert_redirected_to "/session/new"
      end
    end
  RUBY

  file "style.md", <<~'MD'
    
    # Style
    
    We aim to write code that is a pleasure to read, and we have a lot of opinions about how to do it well. Writing great code is an essential part of our programming culture, and we deliberately set a high bar for every code change anyone contributes. We care about how code reads, how code looks, and how code makes you feel when you read it.
    
    When writing new code, unless you are very familiar with our approach, try to find similar code elsewhere in the codebase for inspiration.
    
    ## Ruby Style
    
    ### Use Rails generators
    
    Always use Rails generators to create models, migrations, controllers, mailers, and jobs. Never create these files by hand unless truly necessary. Generators ensure consistent file placement, naming conventions, test stubs, and boilerplate.
    
    ```bash
    bin/rails generate model Plan name:string organization:references
    bin/rails generate migration AddStatusToPlans status:string
    bin/rails generate controller Plans index show
    bin/rails generate mailer AlertMailer weekly_summary
    bin/rails generate job DataSync
    ```
    
    This applies to migrations especially—always generate them rather than writing migration files manually.
    
    ### Always use named arguments
    
    Always pass keyword arguments explicitly. Never rely on positional arguments when calling methods that accept keyword args—even when the variable name matches the parameter name.
    
    ```ruby
    # Bad — implicit shorthand is cryptic
    Plaid::AccountsGetRequest.new(access_token:)
    
    # Good — always spell it out
    Plaid::AccountsGetRequest.new(access_token: access_token)
    ```
    
    ```ruby
    # Bad
    magic_links.create!(purpose:)
    
    # Good
    magic_links.create!(purpose: purpose)
    ```
    
    ### No single-line method definitions
    
    Don't use the single-line `def ... = ...` syntax. Always use the standard multi-line `def ... end` form.
    
    ```ruby
    # Bad
    def name = "#{first_name} #{last_name}"
    
    # Good
    def name
      "#{first_name} #{last_name}"
    end
    ```
    
    ### Conditional returns
    
    In general, we prefer to use expanded conditionals over guard clauses.
    
    ```ruby
    # Bad
    def create
      magic_link = MagicLink.consume(params.require(:code).to_s.strip)
      return redirect_to(new_session_path, alert: "Invalid code.") unless magic_link
      start_new_session_for magic_link.user
      redirect_to new_onboarding_path
    end
    
    # Good
    def create
      magic_link = MagicLink.consume(params.require(:code).to_s.strip)
    
      if magic_link
        start_new_session_for magic_link.user
        redirect_to new_onboarding_path
      else
        render inertia: "auth/verify", props: {
          code_length: MagicLink::CODE_LENGTH,
          expiration_minutes: (MagicLink::EXPIRATION_TIME / 60).to_i,
          error: "Invalid or expired code. Please try again."
        }
      end
    end
    ```
    
    As an exception, we sometimes use guard clauses to return early from a method:
    
    * When the return is right at the beginning of the method.
    * When the main method body is not trivial and involves several lines of code.
    
    ```ruby
    def new
      return redirect_to(root_path) if Current.organization
    
      render inertia: "onboarding/organization"
    end
    ```
    
    ### Methods ordering
    
    We order methods in classes in the following order:
    
    1. `class` methods
    2. `public` methods with `initialize` at the top.
    3. `private` methods
    
    ```ruby
    class MagicLink < ApplicationRecord
      class << self
        def consume(code)
          active.find_by(code: code.to_s.strip.downcase)&.tap(&:destroy)
        end
    
        def cleanup
          stale.delete_all
        end
      end
    
      private
    
      def generate_code
        # ...
      end
    
      def set_expiration
        # ...
      end
    end
    ```
    
    ### Invocation order
    
    We order methods vertically based on their invocation order. This helps us to understand the flow of the code.
    
    ```ruby
    module Authentication
      private
    
      def require_authentication
        resume_session || request_authentication
      end
    
      def resume_session
        if session = find_session_by_cookie
          Current.session = session
        end
      end
    
      def find_session_by_cookie
        Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
      end
    
      def request_authentication
        session[:return_to_after_authenticating] = request.url
        redirect_to new_session_path
      end
    end
    ```
    
    ### To bang or not to bang
    
    We only use `!` for methods that have a corresponding counterpart without `!`. We don't use `!` to flag destructive actions.
    
    ### Visibility modifiers
    
    We don't add a newline under visibility modifiers, and we indent the content under them.
    
    ```ruby
    class Organization < ApplicationRecord
      has_many :memberships, class_name: "Organization::Membership", dependent: :destroy
      has_many :users, through: :memberships
    
      before_validation :assign_slug, on: :create
    
      private
        def assign_slug
          return if slug.present? || name.blank?
    
          self.slug = "#{name.parameterize}-#{SecureRandom.hex(4)}"
        end
    end
    ```
    
    If a module only has private methods, we mark it `private` at the top and add an extra newline after but don't indent.
    
    ```ruby
    module RequireOrganization
      extend ActiveSupport::Concern
    
      included do
        before_action :set_current_organization, if: :authenticated?
        before_action :require_organization, if: :authenticated?
      end
    
      class_methods do
        def allow_missing_organization(**options)
          skip_before_action :require_organization, **options
        end
      end
    
      private
    
      def set_current_organization
        Current.organization = Current.user&.organizations&.first
      end
    
      def require_organization
        return if Current.organization
    
        redirect_to new_onboarding_path, status: :see_other
      end
    end
    ```
    
    ### CRUD controllers
    
    We model web endpoints as CRUD operations on resources (REST). When an action doesn't map cleanly to a standard CRUD verb, we introduce a new resource rather than adding custom actions.
    
    ```ruby
    # Bad
    resources :sessions do
      post :verify
    end
    
    # Good — magic link verification is its own resource nested under sessions
    resource :session, only: %i[ new create destroy ] do
      scope module: :sessions do
        resource :magic_link, only: %i[ show create ]
      end
    end
    ```
    
    ### Controller and model interactions
    
    We favor a vanilla Rails approach with thin controllers directly invoking a rich domain model. We don't use services or other artifacts to connect the two.
    
    Invoking plain Active Record operations is totally fine:
    
    ```ruby
    class OnboardingsController < InertiaController
      def create
        organization = Organization.create!(name: organization_params.fetch(:name))
        Current.user.memberships.create!(organization:, role: :admin)
        Current.organization = organization
    
        redirect_to root_path
      end
    end
    ```
    
    When justified, it is fine to use form objects, but don't treat those as special artifacts:
    
    ```ruby
    class SignupsController < InertiaController
      def create
        signup = Signup.new(signup_params)
    
        if signup.create_user
          redirect_to session_magic_link_path
        else
          render inertia: "auth/signup", props: {
            errors: signup.errors.to_hash,
            email_address: signup.email_address,
            name: signup.name
          }, status: :unprocessable_entity
        end
      end
    end
    ```
    
    ### Run async operations in jobs
    
    We write shallow job classes that delegate the logic itself to domain models:
    
    * We use the suffix `_later` for methods that enqueue a job.
    * When a model class enqueues a job that invokes a method on that same class, we use `_now` for the synchronous method.
    
    ```ruby
    class User < ApplicationRecord
      def send_magic_link_later(**attributes)
        attributes[:purpose] = attributes.delete(:for) if attributes.key?(:for)
        magic_links.create!(attributes).tap do |magic_link|
          MagicLinkMailer.sign_in_instructions(magic_link).deliver_later
        end
      end
    end
    ```
    
    ### Concerns: shared vs. scoped
    
    `app/models/concerns/` and `app/controllers/concerns/` are for **high-level concerns applicable across many models or controllers**. These represent broadly shared behavior like authentication, ID generation, or timestamps.
    
    ```ruby
    # app/controllers/concerns/authentication.rb — used by all controllers
    module Authentication
      extend ActiveSupport::Concern
    
      included do
        before_action :require_authentication
        helper_method :authenticated?
      end
    
      class_methods do
        def allow_unauthenticated_access(**options)
          skip_before_action :require_authentication, **options
        end
      end
    end
    
    # app/models/concerns/nanoid_generator.rb — used by any model that needs public IDs
    module NanoidGenerator
      extend ActiveSupport::Concern
      # ...
    end
    ```
    
    **Scoped concerns** that are specific to a single model or model namespace live alongside that model, not in `app/models/concerns/`. They are namespaced under the model they belong to.
    
    ```ruby
    # app/models/institution/plaid/token_management.rb — only used by Institution::Plaid
    module Institution::Plaid::TokenManagement
      extend ActiveSupport::Concern
      # ...
    end
    
    # app/models/institution/plaid.rb
    class Institution::Plaid < ApplicationRecord
      include Institution::Plaid::TokenManagement
    end
    ```
    
    The rule of thumb: if a concern is only relevant to one model or one namespace, it lives next to that model. If it's broadly useful, it goes in `concerns/`.
    
    ### Scoping data to the organization
    
    All tenant-scoped queries should be scoped through `Current.organization` or the parent association chain. Never query tenant data globally.
    
    ```ruby
    # Bad
    Plan.find(params[:id])
    
    # Good
    Current.organization.plans.find(params[:id])
    ```
    
    ### Current attributes
    
    We use `Current` for request-scoped state. Keep it minimal—only session and organization.
    
    ```ruby
    class Current < ActiveSupport::CurrentAttributes
      attribute :session, :organization
      delegate :user, to: :session, allow_nil: true
    end
    ```
    
    ### Inertia rendering
    
    Controllers inherit from `InertiaController` (which shares auth and flash data) and render Inertia pages with `render inertia:`. Props are passed inline.
    
    ```ruby
    class SessionsController < InertiaController
      def new
        render inertia: "auth/login"
      end
    end
    
    class Sessions::MagicLinksController < InertiaController
      def show
        render inertia: "auth/verify", props: {
          code_length: MagicLink::CODE_LENGTH,
          expiration_minutes: (MagicLink::EXPIRATION_TIME / 60).to_i
        }
      end
    end
    ```
    
    ## TypeScript & React Style
    
    ### Page components
    
    Page components are the entry point for Inertia pages. They are default exports with `Page` suffix names.
    
    ```tsx
    type Props = SharedProps
    
    export default function LoginPage(_props: Props) {
      const form = useForm({
        email_address: "",
      })
    
      return (
        <section className="mx-auto w-full max-w-md space-y-8 py-6">
          {/* ... */}
        </section>
      )
    }
    ```
    
    ### Props typing
    
    Always type page props explicitly. Extend `SharedProps` for page-level props that include auth and flash data. Use server-provided defaults via destructured props.
    
    ```tsx
    import type { SharedProps } from "@/types"
    
    type Props = SharedProps & {
      errors?: Record<string, string[]>
      email_address?: string
      name?: string
    }
    
    export default function SignupPage({
      errors = {},
      email_address = "",
      name = "",
    }: Props) {
      // ...
    }
    ```
    
    ### Forms
    
    Use Inertia's `useForm` hook for all form submissions. No raw `fetch` or `axios` calls. Use `form.transform` to nest data under a resource key when needed.
    
    ```tsx
    const form = useForm({
      email_address,
      name,
    })
    
    // Simple post
    form.post("/session")
    
    // Nested under a resource key
    form.transform((data) => ({ signup: data }))
    form.post("/signup")
    ```
    
    ### Form layout pattern
    
    Forms follow a consistent structure: section wrapper, header with title and subtitle, form element with `space-y-4`, field groups with label + input + error, and a full-width submit button.
    
    ```tsx
    <section className="mx-auto w-full max-w-md space-y-8 py-6">
      <div className="space-y-1">
        <h1 className="text-2xl font-semibold">Create account</h1>
        <p className="text-sm text-muted-foreground">
          Already have an account?{" "}
          <Link href="/session/new" className="text-primary underline-offset-4 hover:underline">
            Sign in
          </Link>
        </p>
      </div>
    
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="space-y-2">
          <Label htmlFor="name">Name</Label>
          <Input
            id="name"
            value={form.data.name}
            onChange={(event) => form.setData("name", event.target.value)}
            disabled={form.processing}
          />
          {errors.name ? <p className="text-sm text-destructive">{errors.name.join(", ")}</p> : null}
        </div>
    
        <Button type="submit" className="w-full" disabled={form.processing}>
          {form.processing ? "Sending..." : "Send One-Time Code"}
        </Button>
      </form>
    </section>
    ```
    
    ### Component organization
    
    - UI primitives live in `@/components/ui/` (shadcn/ui)
    - Feature components live in `@/components/`
    - Layouts live in `@/layouts/`
    - Custom hooks live in `@/hooks/`
    - Types live in `@/types/`
    
    ### Styling
    
    - Use Tailwind utility classes exclusively—no custom CSS for components
    - Use `cn()` from `@/lib/utils` to merge conditional class names
    - Use CSS custom properties (defined in `application.css`) via Tailwind's semantic tokens for theming
    - Prefer semantic color tokens (`text-muted-foreground`, `bg-card`, `text-destructive`) over raw color values
    
    ### Conditional rendering
    
    Prefer ternary with `null` for simple conditions.
    
    ```tsx
    {form.errors.email_address ? (
      <p className="text-sm text-destructive">{form.errors.email_address}</p>
    ) : null}
    ```
    
    ### Import ordering
    
    1. Type imports
    2. Inertia imports
    3. Component imports (`@/components/`)
    4. Hook imports (`@/hooks/`)
    5. Utility imports (`@/lib/`)
    
    ```tsx
    import type { SharedProps } from "@/types"
    import { Link, useForm } from "@inertiajs/react"
    import { Button } from "@/components/ui/button"
    import { Input } from "@/components/ui/input"
    import { Label } from "@/components/ui/label"
    ```
    
    ## Testing Style
    
    ### Never use fake data in tests
    
    Test data—fixtures and inline records—should use realistic names that match real-world entities. Never invent obviously fake placeholder names.
    
    ```ruby
    # Bad
    account = institution.accounts.create!(name: "No Balance Account", external_id: "test_123")
    organization = Organization.create!(name: "Test Org")
    
    # Good
    account = institution.accounts.create!(name: "Business Savings", external_id: "acct_savings_001")
    organization = Organization.create!(name: "Sabre")
    ```
  MD

  file "AGENTS.md", <<~MD
    # Agent Instructions

    Follow conventions in `@style.md`.
  MD

  rails_command "db:prepare"
end
