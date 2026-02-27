# frozen_string_literal: true

gem "inertia_rails"
gem "nanoid", require: false
gem "name_of_person"

gsub_file "Gemfile", /^gem ["']turbo-rails["'].*\n/, ""
gsub_file "Gemfile", /^gem ["']stimulus-rails["'].*\n/, ""

def migration_number(offset)
  @migration_start ||= Time.now.utc.strftime("%Y%m%d%H%M%S").to_i
  (@migration_start + offset).to_s
end

after_bundle do
  append_to_file "Gemfile", <<~RUBY
    gem "vite_rails", "~> 3.0"
  RUBY
  run "bundle install"

  run "npm add react react-dom @inertiajs/react"
  run "npm add -D typescript @types/react @types/react-dom @vitejs/plugin-react @tailwindcss/vite"

  file "config/vite.json", <<~JSON
    {
      "all": {
        "sourceCodeDir": "app/frontend",
        "watchAdditionalPaths": []
      },
      "development": {
        "autoBuild": true,
        "publicOutputDir": "vite-dev",
        "port": 3036
      },
      "test": {
        "autoBuild": true,
        "publicOutputDir": "vite-test",
        "port": 3037
      },
      "production": {
        "autoBuild": false,
        "publicOutputDir": "vite"
      }
    }
  JSON

  file "vite.config.ts", <<~TS
    import react from "@vitejs/plugin-react"
    import tailwindcss from "@tailwindcss/vite"
    import { defineConfig } from "vite"
    import RubyPlugin from "vite-plugin-ruby"

    export default defineConfig({
      plugins: [react(), tailwindcss(), RubyPlugin()],
    })
  TS

  file "config/initializers/inertia_rails.rb", <<~RUBY
    InertiaRails.configure do |config|
      config.version = ViteRuby.digest
      config.encrypt_history = true
      config.always_include_errors_hash = true
      config.use_script_element_for_initial_page = true
      config.use_data_inertia_head_attribute = true
    end
  RUBY

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

  append_to_file "config/environments/development.rb", <<~RUBY

    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: "127.0.0.1",
      port: 1025,
      domain: "localhost"
    }
    config.action_mailer.raise_delivery_errors = false
    config.action_mailer.default_url_options = { host: "localhost", port: 3000 }
  RUBY

  append_to_file "config/environments/production.rb", <<~RUBY

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

      def send_magic_link_later
        magic_links.create!(purpose: :sign_in).tap do |magic_link|
          MagicLinkMailer.sign_in_instructions(magic_link).deliver_later
        end
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

      enum :purpose, { sign_in: "sign_in" }, prefix: :for, default: :sign_in

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

  file "app/controllers/application_controller.rb", <<~RUBY
    class ApplicationController < ActionController::Base
      include Authentication
      include RequireOrganization
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

  file "app/controllers/sessions/magic_links_controller.rb", <<~RUBY
    module Sessions
      class MagicLinksController < InertiaController
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

  file "app/frontend/entrypoints/inertia.tsx", <<~TSX
    import { createInertiaApp, type ResolvedComponent } from "@inertiajs/react"
    import type { ReactNode } from "react"
    import { StrictMode } from "react"
    import { createRoot } from "react-dom/client"
    import { AuthLayout } from "../layouts/auth-layout"
    import { AppLayout } from "../layouts/app-layout"

    void createInertiaApp({
      resolve: (name) => {
        const pages = import.meta.glob<{ default: ResolvedComponent }>("../pages/**/*.tsx", { eager: true })
        const page = pages[`../pages/\${name}.tsx`]

        if (!page) {
          throw new Error(`Missing Inertia page component: \${name}.tsx`)
        }

        if (name.startsWith("auth/") || name.startsWith("onboarding/")) {
          page.default.layout ??= (pageContent: ReactNode) => <AuthLayout>{pageContent}</AuthLayout>
        }

        if (name.startsWith("dashboard/")) {
          page.default.layout ??= (pageContent: ReactNode) => <AppLayout>{pageContent}</AppLayout>
        }

        return page
      },
      setup({ el, App, props }) {
        createRoot(el).render(
          <StrictMode>
            <App {...props} />
          </StrictMode>,
        )
      },
    })
  TSX

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

  file "db/migrate/#{migration_number(1)}_create_users.rb", <<~RUBY
    class CreateUsers < ActiveRecord::Migration[8.0]
      def change
        create_table :users do |t|
          t.string :first_name
          t.string :last_name
          t.string :email_address, null: false
          t.index :email_address, unique: true
          t.timestamps
        end
      end
    end
  RUBY

  file "db/migrate/#{migration_number(2)}_create_sessions.rb", <<~RUBY
    class CreateSessions < ActiveRecord::Migration[8.0]
      def change
        create_table :sessions do |t|
          t.references :user, null: false, foreign_key: true
          t.string :ip_address
          t.string :user_agent
          t.timestamps
        end
      end
    end
  RUBY

  file "db/migrate/#{migration_number(3)}_create_magic_links.rb", <<~RUBY
    class CreateMagicLinks < ActiveRecord::Migration[8.0]
      def change
        create_table :magic_links do |t|
          t.references :user, null: false, foreign_key: true
          t.string :code, null: false
          t.string :purpose, null: false
          t.datetime :expires_at, null: false
          t.index :code, unique: true
          t.index :expires_at
          t.timestamps
        end
      end
    end
  RUBY

  file "db/migrate/#{migration_number(4)}_create_organizations.rb", <<~RUBY
    class CreateOrganizations < ActiveRecord::Migration[8.0]
      def change
        create_table :organizations do |t|
          t.string :name, null: false
          t.string :slug, null: false
          t.index :slug, unique: true
          t.timestamps
        end
      end
    end
  RUBY

  file "db/migrate/#{migration_number(5)}_create_organization_memberships.rb", <<~RUBY
    class CreateOrganizationMemberships < ActiveRecord::Migration[8.0]
      def change
        create_table :organization_memberships do |t|
          t.references :organization, null: false, foreign_key: true
          t.references :user, null: false, foreign_key: true
          t.string :role, null: false, default: "owner"
          t.index [:organization_id, :user_id], unique: true
          t.timestamps
        end
      end
    end
  RUBY

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

  file "README.md", <<~MD
    # Rails B2B Template

    Playbook-style Rails starter with:
    - Magic-link sign-in
    - Organization onboarding and membership
    - Inertia + React + TypeScript + Vite
    - AWS SES SMTP production mailer defaults

    ## Usage (local template)

    ```bash
    rails new my_app -d postgresql --skip-javascript --skip-hotwire -m /path/to/rails-b2b/template.rb
    ```

    ## Usage (from git)

    ```bash
    rails new my_app -d postgresql --skip-javascript --skip-hotwire -m https://raw.githubusercontent.com/<you>/rails-b2b/main/template.rb
    ```

    ## AWS SES setup

    Add credentials:

    ```bash
    bin/rails credentials:edit
    ```

    ```yaml
    aws:
      smtp_username: your_smtp_username
      smtp_password: your_smtp_password
    ```

    ## Dev mail

    Template defaults dev SMTP to `127.0.0.1:1025` (Mailpit/Mailcatcher style).
  MD

  run "mkdir -p files bin"
  file "files/.keep", ""
  file "bin/new", <<~BASH
    #!/usr/bin/env bash
    set -euo pipefail

    APP_NAME="${1:-demo_b2b}"
    TEMPLATE_PATH="${2:-#{File.expand_path("template.rb", destination_root)}}"

    rails new "$APP_NAME" -d postgresql --skip-javascript --skip-hotwire -m "$TEMPLATE_PATH"
  BASH
  run "chmod +x bin/new"

  rails_command "db:migrate"
  rails_command "test"
end
