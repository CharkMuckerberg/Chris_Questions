module UserIdentification
  extend ActiveSupport::Concern

  included do
    before_action :resume_user
  end

  private
    def resumse_user
      Current.user = User.find_signed(
        cookies[:user_token],
        purpose: :user
      )
    end
  end
end
