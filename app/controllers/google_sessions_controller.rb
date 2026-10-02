require "net/http"

class GoogleSessionsController < ApplicationController
  ISSUER_URL = "https://deccanqueenonrails.com/chat/login"

  allow_unauthenticated_access
  before_action :ensure_enabled

  def create
    if params[:join_code].present? && params[:join_code] != Current.account.join_code
      return head :not_found
    end

    state = SecureRandom.alphanumeric(32)
    options = { httponly: true, same_site: :lax, secure: request.ssl?, expires: 10.minutes.from_now }
    cookies.signed[:google_login_state] = options.merge(value: state)
    cookies.signed[:google_join_code] = options.merge(value: params[:join_code])
    redirect_to "#{issuer_url}?state=#{state}", allow_other_host: true, status: :see_other
  end

  def show
    state = cookies.signed[:google_login_state]
    join_code = cookies.signed[:google_join_code]
    cookies.delete(:google_login_state)
    cookies.delete(:google_join_code)

    unless state.present? && params[:state].is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(state, params[:state])
      return reject_login
    end
    return reject_login unless params[:login_code].is_a?(String) && params[:login_code].match?(/\A[A-Za-z0-9_-]{43}\z/)

    identity = redeem(params[:login_code], state)
    return reject_login unless identity.is_a?(Hash) && identity["verified"] == true && identity["email"].is_a?(String)

    email = identity["email"].strip.downcase
    return reject_login unless email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) && email.length <= 255

    user = User.where("lower(email_address) = ?", email).first
    if user
      return reject_login unless user.active? && !user.bot?
    else
      unless join_code.present? && join_code == Current.account.join_code
        return reject_login("Use the conference invite link to create your chat account.")
      end
      name = identity["name"].to_s.strip.presence || email.split("@").first
      user = User.create!(email_address: email, name: name.first(255))
    end

    apply_verified_access(user, email)
    start_new_session_for user
    redirect_to post_authenticating_url
  rescue ActiveRecord::RecordNotUnique
    reject_login
  end

  private
    def ensure_enabled
      head :not_found unless ENV["GOOGLE_LOGIN_ENABLED"] == "true"
    end

    def issuer_url
      Rails.env.production? ? ISSUER_URL : ENV.fetch("GOOGLE_LOGIN_ISSUER_URL", ISSUER_URL)
    end

    def redeem(login_code, state)
      uri = URI.parse("#{issuer_url}/redeem")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = http.read_timeout = 5
      request = Net::HTTP::Post.new(uri.request_uri)
      request.set_form_data(login_code: login_code, state: state)
      response = http.request(request)
      JSON.parse(response.body) if response.code == "200"
    rescue StandardError
      nil
    end

    def reject_login(message = "Google sign-in failed. Please try again.")
      redirect_to new_session_url, alert: message
    end

    def apply_verified_access(user, email)
      administrators = ENV.fetch("CAMPFIRE_ADMIN_EMAILS", "").split(",").map { |value| value.strip.downcase }
      user.update!(role: :administrator) if administrators.include?(email) && !user.administrator?

      speakers = ENV.fetch("CAMPFIRE_SPEAKER_EMAILS", "").split(",").map { |value| value.strip.downcase }
      if speakers.include?(email) && room = Rooms::Closed.find_by(id: ENV["CAMPFIRE_SPEAKER_ROOM_ID"])
        if user.memberships.where(room_id: room.id).first.nil?
          user.memberships.create!(room_id: room.id)
        end
      end
    end
end
