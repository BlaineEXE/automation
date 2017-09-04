require "spec_helper"
require 'yaml'

feature "Register user and configure cluster" do

  before(:each) do
    unless self.inspect.include? "User registers"
      login
    end
  end

  # Using append after in place of after, as recommended by
  # https://github.com/mattheworiordan/capybara-screenshot#common-problems
  append_after(:each) do
    Capybara.reset_sessions!
  end

  scenario "User registers" do
    with_screenshot(name: :register) do
      puts ">>> Registering user"
      visit "/users/sign_up"
      fill_in "user_email", with: "test@test.com"
      fill_in "user_password", with: "password"
      fill_in "user_password_confirmation", with: "password"
      click_on "Create Admin"
      puts "<<< User registered"
    end
  end

  scenario "User configures the cluster" do
    with_screenshot(name: :configure) do
      puts ">>> Setting up velum"
      visit "/setup"
      fill_in "settings_dashboard", with: environment["dashboardHost"] || default_ip_address
      click_on "Next"
      puts "<<< Velum set up"
    end
  end

  scenario "User proceeds past AutoYaST page" do
    with_screenshot(name: :skip_autoyast) do
      puts ">>> Skipping past the AutoYaST page"
      visit "/setup/worker-bootstrap"
      click_on "Next"
      puts "<<< Skipped past the AutoYaST page"
    end
  end
end
