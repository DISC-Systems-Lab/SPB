class VoteController < ApplicationController
  before_action :set_no_cache, if: :real_voting?
  before_action :check_voter, only: [:approval, :submit_approval, :ranking, :submit_ranking, :knapsack, :submit_knapsack, :comparison, :submit_comparison, :thanks_approval, :question, :survey, :done_survey, :thanks]
  helper_method :conf, :voting_machine?, :real_voting?, :next_page, :current_action
  before_action :update_locales_with_config

  def index
    I18n.locale = params[:locale] ? params[:locale] : conf[:default_locale]
  end

  # Approval voting
  def approval
    return if !update_stage(:approval)
    load_projects_and_categories

    # Store whether we shuffle the projects.
    if current_voter
      current_voter.update_data(shuffled: @shuffled)
    end

    @submit_url = url_for(action: :submit_approval, subpage: @current_subpage)
  end

  # Save approval vote to the database
  def submit_approval
    if !current_voter.nil? && !current_voter.test? && !conf[:stop_accepting_votes]
      # Check if vote already exists (from the same voter on the same approval page)
      vote_exists = current_voter.vote_approvals
        .joins('INNER JOIN projects ON vote_approvals.project_id = projects.id')
        .joins('INNER JOIN categories ON projects.category_id = categories.id')
        .where('categories.category_group = ?', conf[:approval][:pages][current_subpage])
      if vote_exists.empty?
        voter = current_voter
        election = current_election

        ActiveRecord::Base.transaction do
          total_cost = 0
          n_projects = 0
          ranks = []
          election.projects.each do |project|
            cost = params[:project][project.id.to_s].to_i
            if cost != 0
              # Check if a similar vote already exists
              vote_exists = VoteApproval.where('voter_id = ' + voter.id.to_s + ' AND project_id = ' + project.id.to_s)
              break if !vote_exists.empty?

              vote_approval = VoteApproval.new
              vote_approval.voter = voter
              vote_approval.project = project
              vote_approval.cost = cost
              if conf[:approval][:project_ranking]
                rank = params[:project_rank][project.id.to_s].to_i
                vote_approval.rank = rank
                ranks << rank
              end
              vote_approval.save!
              total_cost += cost
              n_projects += 1 if !project.mandatory?
            end
          end
          raise 'error' if conf[:approval][:has_budget_limit] && total_cost > election.budget
          raise 'error' if conf[:approval][:has_n_project_limit] && (n_projects > conf[:approval][:max_n_projects] || n_projects < conf[:approval][:min_n_projects])
          raise 'error' if conf[:approval][:project_ranking] && ranks.sort.each_with_index.any? { |rank, i| rank != i + 1 }
        end

        current_voter.update_data('locale' => I18n.locale)  # record the language the voter is using
      end
    end

    if current_subpage >= conf[:approval][:pages].length - 1
      redirect_to next_page(:approval)
    else
      redirect_to(action: :approval, subpage: current_subpage + 1)
    end
  end

  # Ranking voting
  def ranking  # just approval + ranking
    return if !update_stage(:ranking)
    load_projects_and_categories
    @submit_url = url_for(action: :submit_ranking)
    render action: :approval
  end

  # Save ranking vote to the database
  def submit_ranking
    if !current_voter.nil? && !current_voter.test? && !conf[:stop_accepting_votes]
      # Check if vote already exists (from the same voter on the same approval page)
      vote_exists = current_voter.vote_approvals
        .joins('INNER JOIN projects ON vote_approvals.project_id = projects.id')
        .joins('INNER JOIN categories ON projects.category_id = categories.id')
        .where('categories.category_group = ?', conf[:ranking][:pages][current_subpage])
      if vote_exists.empty?
        voter = current_voter
        election = current_election

        ActiveRecord::Base.transaction do
          n_projects = 0
          ranks = []
          election.projects.each do |project|
            cost = params[:project][project.id.to_s].to_i
            rank = params[:project_rank][project.id.to_s].to_i
            if rank > 0
              # Check if a similar vote already exists
              vote_exists = VoteApproval.where('voter_id = ' + voter.id.to_s + ' AND project_id = ' + project.id.to_s)
              break if !vote_exists.empty?

              vote_approval = VoteApproval.new
              vote_approval.voter = voter
              vote_approval.project = project
              vote_approval.cost = cost
              vote_approval.rank = rank
              vote_approval.save!
              n_projects += 1
              ranks << rank
            end
          end
          raise 'error' if conf[:ranking][:has_n_project_limit] && (n_projects > conf[:ranking][:max_n_projects] || n_projects < conf[:ranking][:min_n_projects])
          raise 'error' if ranks.sort.each_with_index.any? { |rank, i| rank != i + 1 }
        end

        current_voter.update_data('locale' => I18n.locale)  # record the language the voter is using
      end
    end

    redirect_to next_page(:ranking)
  end

  def thanks_approval
    # Send an sms for thanks approval
    send_thanks_approval_sms if (current_voter && conf[:voter_registration] && conf[:send_vote_sms])
    return if !update_stage(:thanks_approval)  # FIXME: What is this?
  end

  def send_vote_email
    if current_voter
      email = params[:email]
      voter = current_voter
      voter_results = voter.vote_approvals.map{ |approval| approval.project.title }
      UserMailer.vote_result_email(email, voter_results).deliver
      render json: {
        message: "Email sent!"
      }
    else
      render json: {
        message: 'Sorry, a problem has occured. The email could not be sent.'
      }
    end
  end

  # Comparison voting
  def comparison
    return if !update_stage(:comparison)
    @election = current_election
    projects = @election.projects.where(adjustable_cost: false) # TODO: Include adjustable cost projects in some way?

    @projects_json = projects.as_json(only: [:id, :title, :description, :cost, :address, :partner, :committee], methods: :image_url)

    project_tuples = (0...@projects_json.length).map { |i| [i, @projects_json[i]['cost']] }
    @pairs = project_tuples.combination(2).to_a.sample(conf[:comparison][:n_pairs]).map { |pair| pair.shuffle }
  end

  # Save comparison vote to the database
  def submit_comparison
    if !current_voter.nil? && !current_voter.test? && !conf[:stop_accepting_votes] && current_voter.vote_comparisons.count < conf[:comparison][:n_pairs]
      voter = current_voter

      # TODO: Verify that first_project_id and second_project_id are what we generated.
      vote_comparison = VoteComparison.new
      vote_comparison.voter = voter
      vote_comparison.first_project_id = params[:first_project_id]
      vote_comparison.first_project_cost = params[:first_project_cost]
      vote_comparison.second_project_id = params[:second_project_id]
      vote_comparison.second_project_cost = params[:second_project_cost]
      vote_comparison.result = params[:result]
      vote_comparison.save!
    end

    render nothing: true
  end

  def done_comparison
    redirect_to next_page(:comparison)
  end

  # Knapsack voting
  def knapsack  # just approval + budgetbar
    return if !update_stage(:knapsack)
    load_projects_and_categories
    @submit_url = url_for(action: :submit_knapsack)
    render action: :approval
  end

  # Save Knapsack vote to the database
  def submit_knapsack
    if !current_voter.nil? && !current_voter.test? && !conf[:stop_accepting_votes] && current_voter.vote_knapsacks.empty?  # TODO: the last clause is hacky
      voter = current_voter
      election = current_election
      ActiveRecord::Base.transaction do
        total_cost = 0
        election.projects.each do |project|
          cost = params[:project][project.id.to_s].to_i
          if cost != 0
            vote_knapsack = VoteKnapsack.new
            vote_knapsack.voter = voter
            vote_knapsack.project = project
            vote_knapsack.cost = cost
            vote_knapsack.save!
            total_cost += cost
          end
        end
        raise 'error' if conf[:knapsack][:has_budget_limit] && total_cost > election.budget
        raise 'error' if conf[:knapsack][:has_n_project_limit] && (n_projects > conf[:knapsack][:max_n_projects] || n_projects < conf[:knapsack][:min_n_projects])
      end
    end

    redirect_to next_page(:knapsack)
  end

  # Survey (just an <iframe> to an external website, e.g. Qualtrics)
  def survey
    return if !update_stage(:survey)

    if !real_voting?
      redirect_to next_page(:survey)  # skip the survey for the demo mode
    end
  end

  def done_survey
    # Can't do "redirect_to next_page(:survey)", because this is called from inside
    # an <iframe>. We want to redirect the entire page. So, we use a JavaScript redirect.
    render html: ("<html><script>window.top.location.href = \"" + url_for(next_page(:survey)) + "\";</script></html>").html_safe
    response.headers.delete('X-Frame-Options')
  end

  def thanks
    return if !update_stage(:thanks)
  end

  # Code for public results/analytics page
  def results
    @election = current_election
    if !@election.config[:show_public_results]
      raise ActionController::RoutingError.new('Not Found')
    end

    workflow = @election.config[:workflow].flatten
    if workflow.include?('approval')
      @projects = @election.projects.joins('LEFT OUTER JOIN vote_approvals ON vote_approvals.project_id = projects.id ' \
        'LEFT OUTER JOIN voters ON voters.id = vote_approvals.voter_id AND voters.void = 0')
        .select('projects.*, COUNT(voters.id) + COALESCE(projects.external_vote_count, 0) AS vote_count')
        .where('projects.adjustable_cost = 0')
        .group('projects.id').order('vote_count DESC').map do |p|
        {
          id: p.id,
          title: p.title,
          cost: p.cost,
          vote_count: p.vote_count
        }
      end
      @approvals = @projects  # hacky

      @max_approval_vote_count = @projects.map { |p| p[:vote_count] }.max

      @has_adjustable_cost_projects = @election.projects.exists?(adjustable_cost: true)

      if @has_adjustable_cost_projects
        total_votes = @election.voters.where('void = 0 AND stage IS NOT NULL AND stage != \'approval\'').count  # FIXME: Not a good way to count.

        @adjustable_cost_projects = @election.projects.where(adjustable_cost: true).map do |project|
          # Get the vote count for each cost from the table.
          vote_counts = {}
          adjustable_project_data = project.vote_approvals.select('cost, COUNT(*) AS vote_count')
            .joins(:voter).where('voters.void = 0').group(:cost)
          adjustable_project_data.each do |vp|
            vote_counts[vp.cost] = vp.vote_count
          end

          # FIXME: Since we don't create a vote_approval row with cost=0, we have to use this.
          if project.cost_min == 0
            raise "error" if vote_counts.key?(0)
            vote_counts[0] = total_votes - vote_counts.values.sum
          end

          # For projects that use radio buttons, set the vote count for options that haven't received any votes to 0.
          if !project.uses_slider
            (project.cost_min..project.cost).step(project.cost_step).each do |cost|
              vote_counts[cost] = 0 if !vote_counts.key?(cost)
            end
          end

          {
            title: project.title,
            vote_counts: vote_counts,
            max_vote_count: vote_counts.values.max.to_i,
            average_cost: (total_votes > 0) ? (vote_counts.map { |cost, vote_count| cost * vote_count }.inject(&:+).to_f / total_votes) : nil,
            median_cost: 0,  # TODO: Implement median cost.
          }
        end
      end
    end
  end

  # Code
  def authenticate_code
    @election = current_election
    c = params[:code][:code].downcase.gsub(/\s+/, '')
    code = @election.codes.find_by(code: c)
    if c == '_test'  # hacky
      code = Code.new(code: c)
    end
    if code
      if code.status == 'void'
        # Void code
        flash.now[:error] = 'Void code'
        render :index
        return
      end
      voter = Voter.find_by(election_id: @election.id, authentication_method: 'code', authentication_id: code.code)
      if voter
        if voter.stage == 'done' && !voter.test?
          flash.now[:error] = t('index.voting_machine.used_code')
          render :index
          return
        end
      else
        voter = Voter.new
        voter.election = @election
        voter.authentication_method = 'code'
        voter.authentication_id = code.code
        voter.ip_address = request.remote_ip
        voter.user_agent = request.env['HTTP_USER_AGENT']
        voter.location_id = session[:voting_machine_location_id]
        voter.save!
      end

      session[:voter_id] = voter.id
      if @election.config[:voter_registration]
        redirect_to action: :registration
      else
        redirect_to action: conf[:workflow][0]
      end
    else
      if !c.blank?
        # Wrong code
        flash.now[:error] = t('index.voting_machine.wrong_code')
      end
      render :index
    end
  end

  # SMS signup in remote voting
  def sms_signup
    raise "SMS signup is not allowed" unless conf[:allow_remote_voting] && conf[:remote_voting_sms_verification] && !conf[:stop_accepting_votes]
  end

  def post_sms_signup
    raise "SMS signup is not allowed" unless conf[:allow_remote_voting] && conf[:remote_voting_sms_verification] && !conf[:stop_accepting_votes]

    require 'twilio-ruby'

    @election = current_election
    @phone_number = params['phone_number'].strip

    # Sanitize the phone number to prevent voters from voting multiple times by
    # registering the same phone number under different formats.
    # For example, these are the same numbers:
    # - "123-456-7890" and "1234567890" (Fixed by removing any character other than 0-9 and +)
    # - "+12223334444" and "2223334444" (Fixed by removing the prefix "+1" or "1")
    # FIXME: Does this work outside the US?
    sanitized_phone_number = @phone_number.gsub(/[^0-9+]/, '').sub(/^\+?1/, '')

    voter = Voter.find_by(election_id: @election.id, authentication_method: 'phone', authentication_id: sanitized_phone_number)
    if voter && voter.stage == 'done'
      flash.now[:errors] = ['This number (' + @phone_number + ') has already been used to vote.']
      render action: :sms_signup
      return
    end

    # Generate a 6-digit number whose first digit is not zero. (100000 - 999999)
    confirmation_code = (100000 + rand(900000)).to_s

    twilio_info = Rails.application.secrets[:twilio]
    begin
      # set up a client to talk to the Twilio REST API
      client = Twilio::REST::Client.new twilio_info[:account_sid], twilio_info[:auth_token]
      client.api.account.messages.create({
        from: twilio_info[:phone_number],
        to: @phone_number,
        body: 'Confirmation code for voting: ' + confirmation_code,
      })
    rescue Twilio::REST::RestError => e
      log_activity('sms_signup_failure', note: @phone_number)
      @error = e
      render action: :sms_signup  # TODO: redirect_to
      return
    end

    if voter.nil?
      voter = Voter.new
      voter.election = @election
      voter.authentication_method = 'phone'  # TODO: Change to 'sms'.
      voter.authentication_id = sanitized_phone_number
      voter.ip_address = request.remote_ip
      voter.user_agent = request.env['HTTP_USER_AGENT']
    end
    voter.confirmation_code = confirmation_code
    voter.confirmation_code_created_at = Time.now
    voter.save!
    log_activity('sms_signup_success', note: @phone_number)
    session[:tmp_voter_id] = voter.id
    redirect_to action: :sms_signup_confirm
  end

  # Ask the voter to enter the confirmation code that we have sent to them through SMS.
  def sms_signup_confirm
    raise "SMS signup is not allowed" unless conf[:allow_remote_voting] && conf[:remote_voting_sms_verification] && !conf[:stop_accepting_votes]
    @voter = Voter.find_by(id: session[:tmp_voter_id])
  end

  def post_sms_signup_confirm
    raise "SMS signup is not allowed" unless conf[:allow_remote_voting] && conf[:remote_voting_sms_verification] && !conf[:stop_accepting_votes]
    @election = current_election
    @voter = Voter.find(session[:tmp_voter_id])

    if count_activity('sms_signup_confirm_failure', 1.minute.ago, note: @voter.id) >= 8 ||
      count_activity('sms_signup_confirm_failure', 1.minute.ago, ip_address: request.remote_ip) >= 8
      flash.now[:error] = 'Too many failed attempts. Please wait one minute and try again.'
      render :sms_signup_confirm
      return
    end

    if Time.now - @voter.confirmation_code_created_at > 10.minutes
      flash[:errors] = ['The confirmation code has expired. Please enter your phone number again.']
      redirect_to action: :sms_signup
      return
    end

    if @voter.confirmation_code == params['confirmation_code'].gsub(/\s+/, '')
      log_activity('sms_signup_confirm_success', note: @voter.id)
      session[:voter_id] = session[:tmp_voter_id]
      session.delete(:tmp_voter_id)
      if @election.config[:voter_registration]
        redirect_to action: :registration
      else
        redirect_to action: conf[:workflow][0]
      end
    else
      log_activity('sms_signup_confirm_failure', note: @voter.id)
      flash.now[:error] = t('sms_signup_confirm.wrong_code')
      render :sms_signup_confirm
    end
  end

  # Access code signup in remote voting
  def code_signup
    raise "Code signup is not allowed" unless conf[:allow_remote_voting] && conf[:remote_voting_code_verification] && !conf[:stop_accepting_votes]
  end

  def post_code_signup
    raise "Code signup is not allowed" unless conf[:allow_remote_voting] && conf[:remote_voting_code_verification] && !conf[:stop_accepting_votes]
    @election = current_election

    if count_activity('remote_voting_signup_failure', 1.minute.ago, ip_address: request.remote_ip) >= 5
      flash.now[:error] = 'Too many failed attempts. Please wait one minute and try again.'
      render :code_signup
      return
    end

    c = params[:code][:code].downcase.gsub(/\s+/, '')
    code = @election.codes.find_by(code: c)
    if code
      if code.status == 'void'
        # Void code
        flash.now[:error] = 'Void code'
        render :code_signup
        return
      end
      voter = Voter.find_by(election_id: @election.id, authentication_method: 'remote_code', authentication_id: code.code)
      if voter
        if voter.stage == 'done' && !voter.test?
          flash.now[:error] = t('code_signup.used_access_code')
          render :code_signup
          return
        end
      else
        voter = Voter.new
        voter.election = @election
        voter.authentication_method = 'remote_code'
        voter.authentication_id = code.code
        voter.ip_address = request.remote_ip
        voter.user_agent = request.env['HTTP_USER_AGENT']
        voter.save!
      end

      session[:voter_id] = voter.id
      if @election.config[:voter_registration]
        redirect_to action: :registration
      else
        redirect_to action: conf[:workflow][0]
      end
    else
      log_activity('remote_voting_signup_failure', note: c)
      flash.now[:error] = t('code_signup.wrong_access_code')
      render :code_signup
    end
  end

  # Other signup in remote voting
  def other_signup
    raise "Other signup is not allowed" unless conf[:allow_remote_voting] && conf[:remote_voting_other_verification] && !conf[:stop_accepting_votes]
  end

  def post_other_signup
    raise "Other signup is not allowed" unless conf[:allow_remote_voting] && conf[:remote_voting_other_verification] && !conf[:stop_accepting_votes]
    @election = current_election

    if count_activity('remote_voting_signup_failure', 1.minute.ago, ip_address: request.remote_ip) >= 5
      flash.now[:error] = 'Too many failed attempts. Please wait one minute and try again.'
      render :other_signup
      return
    end

    c = sanitize_code(params[:account_number])
    code = @election.codes.find_by(code: c)
    if code.nil? && !params[:zipcode].blank?  # This is currently only used in Dieppe 2018.
      zipcode = sanitize_code(params[:zipcode])
      c = c + "&" + zipcode
      code = @election.codes.find_by(code: c)
    end
    if code
      if code.status == 'void'
        # Void code
        flash.now[:error] = 'Void code'
        render :other_signup
        return
      end
      voter = Voter.find_by(election_id: @election.id, authentication_method: 'remote_code', authentication_id: code.code)
      if voter
        if voter.stage == 'done' && !voter.test?
          flash.now[:error] = t('other_signup.used_account_number')
          render :other_signup
          return
        end
      else
        voter = Voter.new
        voter.election = @election
        voter.authentication_method = 'remote_code'
        voter.authentication_id = code.code
        voter.ip_address = request.remote_ip
        voter.user_agent = request.env['HTTP_USER_AGENT']
        voter.save!
      end

      if !params[:zipcode].blank?  # This is currently only used in Dieppe 2018.
        voter.update_data(zip_code: params[:zipcode])
      end

      session[:voter_id] = voter.id
      if @election.config[:voter_registration]
        redirect_to action: :registration
      else
        redirect_to action: conf[:workflow][0]
      end
    else
      log_activity('remote_voting_signup_failure', note: c)
      flash.now[:error] = t('other_signup.wrong_account_number')
      render :other_signup
    end
  end

  def registration
    raise "Voter registration is not enabled" unless conf[:voter_registration]

    @election = current_election
    @record = VoterRegistrationRecord.new
  end

  # Method called after voter registration
  def post_registration
    raise "Voter registration is not enabled" unless conf[:voter_registration]

    @election = current_election
    voter = current_voter
    raise 'error' if voter.nil?

    voter_registration_record_params = params.require(:voter_registration_record).permit(@election.config[:voter_registration_questions] - ["age_verify"])
    @record = VoterRegistrationRecord.new(voter_registration_record_params)
    @record.election_id = @election.id
    @record.voter_id = voter.id
    if @record.save
      log_activity('voter_registration_success', note: voter.id)
      redirect_to action: conf[:workflow][0]
    else
      render :registration
    end
  end

  def exit  # Exit without marking the voter as done. The voter can still come back.
    session[:voter_id] = nil
    redirect_to action: :index, locale: conf[:default_locale]
  end

  def done
    update_stage(:done)
    session[:voter_id] = nil
    if !conf[:external_redirect_url].blank?
      redirect_to conf[:external_redirect_url]
    else
      redirect_to action: :index, locale: conf[:default_locale]
    end
  end

  private

  def current_election
    @current_election ||= Election.find_by!(slug: params[:election_slug])
  end

  def current_voter
    if @current_voter.nil?
      @current_voter = Voter.find_by(id: session[:voter_id])
      @current_voter = nil if !@current_voter.nil? && @current_voter.election != current_election
    end
    @current_voter
  end

  # This method is a shorthand for "current_election.config".
  def conf  # Can't name this method 'config' because it conflicts with an internal method.
    if @config.nil?
      @config = current_election.config
    end
    @config
  end

  def update_locales_with_config
    # We do this so that the election's config can overwrite strings in config/locales/*.yml
    Thread.current[:i18n_locales] = conf[:locales]
  end

  def voting_machine?
    # TODO: Check that voting_machine_user_id exists and belongs to this election!
    return !session[:voting_machine_election_id].nil? && session[:voting_machine_election_id].to_i == current_election.id
  end

  def real_voting?  # TODO: use a better name
    voting_machine? || (conf[:allow_remote_voting] && !current_voter.nil?)
  end

  def update_stage(current_page)
    # return false if something is wrong (and a redirect_to is performed)
    if real_voting? && !current_voter.nil? && !current_voter.test?
      stage = current_voter.stage
      if stage
        workflow = conf[:workflow].flatten
        last_index = workflow.index(stage)
        index = workflow.index(current_page.to_s)
        if index && last_index && index < last_index
          redirect_to action: stage
          return false
        end
      end
      current_voter.update_attribute(:stage, current_page)
      current_voter.update_data('timestamps' => {current_page => Time.now.to_i})
    end
    true
  end

  # Find the next page specified in 'workflow' in the configuration
  def next_page(current_page)
    workflow = conf[:workflow]
    if current_page == :home
      index = -1
    else
      index = workflow.index { |o| o.is_a?(Array) ? o.include?(current_page.to_s) : (o == current_page.to_s) }
    end
    action = index ? workflow[index + 1] : :thanks
    if action.is_a?(Array)
      action = action.sample
    end
    {action: action}
  end

  def check_voter
    if real_voting? && current_voter.nil?
      redirect_to action: :index
    end
  end

  def current_action
    params[:action].to_sym
  end

  def current_subpage
    params[:subpage] ? params[:subpage].to_i : 0
  end

  def load_projects_and_categories
    @election = current_election
    @projects_json = @election.projects.as_json(only: [:id, :title, :cost, :cost_min, :cost_step, :map_geometry, :adjustable_cost, :uses_slider], methods: [:image_url, :parsed_data, :mandatory?])
    @current_subpage = current_subpage
    @shuffled = conf[current_action][:shuffle_projects] && rand < conf[current_action][:shuffle_probability]
    @categories = @election.ordered_categories(conf[current_action][:pages][@current_subpage], @shuffled)
  end

  def send_thanks_approval_sms
    require 'twilio-ruby'

    # Get the voter's phone number and send sms if it exists
    voter = current_voter
    record = voter.voter_registration_record
    phone_number = record.nil? ? nil : record.phone_number
    if !phone_number.nil?
      twilio_info = Rails.application.secrets[:twilio]
      begin
        # set up a client to talk to the Twilio REST API
        client = Twilio::REST::Client.new twilio_info[:account_sid], twilio_info[:auth_token]
        client.api.account.messages.create({
          from: twilio_info[:phone_number],
          to: phone_number,
          body: 'Thank you! Your vote has been succesfully recorded.',
        })
      rescue Twilio::REST::RestError => e
        log_activity('sms_failure', note: phone_number)
        @error = e
        return
      end
    else
      log_activity('no_phone_number', note: voter.id.to_s)
    end
  end

  def sanitize_code(c)
    # Remove non-alphanumeric characters and strip leading zeros in the code.
    c.downcase.gsub(/[^0-9a-z_]/, '').sub(/^0+/, '')
  end
end
