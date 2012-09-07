class NotesController < ApplicationController

  include ApplicationHelper

  skip_before_filter :authenticate_user!, :only => [:create_from_mailgun, :update_from_mailgun, :share_view]
  skip_before_filter :set_current_user, :only => [:create_from_mailgun, :update_from_mailgun, :share_view]
  skip_before_filter :verify_authenticity_token, :only => [:create_from_mailgun, :update_from_mailgun]

  # GET /notes
  # GET /notes.json
  def index
    @notes = Note.find_all_by_user_id(current_or_guest_user.id, :order => "updated_at DESC")

    respond_to do |format|
      format.html # index.html.erb
      format.json { render json: @notes }
    end
  end

  # GET /notes/1
  # GET /notes/1.json
  def show
    @note = Note.where(:id => params[:id], :user_id => current_or_guest_user.id).first

    unless @note
      redirect_to '/notes'
    end

    @version_id = (@note.versions.empty? || @note.versions.nil?) ? 0 : @note.versions.last.id

    respond_to do |format|
      format.html # show.html.erb
      format.json { render json: @note }
    end
  end

  # GET /notes/1/versions/1
  # GET /notes/1/versions/1.json
  def show_version
    note = Note.where(:id => params[:id], :user_id => current_or_guest_user.id).first
    version = note.versions.find(params[:version_id]).next
    if version.nil?
      redirect_to "/notes/#{params[:id]}" and return
    end
    @version_id = params[:version_id]
    @note = note.versions.find(params[:version_id]).next.reify

    @versions = note.versions

    respond_to do |format|
      format.html { render "show" }
      format.json { render json: @note }
    end
  end

  def versions
    @note = Note.where(:id => params[:id], :user_id => current_or_guest_user.id).first
    @versions = @note.versions

    respond_to do |format|
      format.html
      format.json { render json: @versions.map { |v| {:id => @note.id, :version_id => v.id, :created_at => v.created_at } } }
    end
  end

  # GET /notes/new
  # GET /notes/new.json
  def new
    current_or_guest_user

    if is_guest? && current_or_guest_user.notes.length == 0
      @note = Note.new(:title => "Your first note", :body => <<HERE)
## Welcome to Marginalia!

This is an example note. Feel free to change all of this.

Notes are formatted with [Markdown](https://www.marginalia.io/markdown),
a simple text markup format. There's a quick formatting guide to the 
right but document linked above has much more info.

Note bodies can contain hash tags, like this: #firstnote
HERE
    else
      @note = Note.new(params[:note])
    end

    @note.user_id = current_or_guest_user.id

    respond_to do |format|
      format.html # new.html.erb
      format.json { render json: @note }
    end
  end

  # GET /notes/1/edit
  def edit
    @note = Note.where(:id => params[:id], :user_id => current_or_guest_user.id).first
  end

  # POST /notes
  # POST /notes.json
  def create
    @note = Note.new(params[:note])
    @note.user_id = current_or_guest_user.id
    @show_modal = current_or_guest_user.notes.length == 0
    @user = current_or_guest_user

    if @note.new_email_address
      @user.email = @note.new_email_address
      unless @user.save
        @user.errors.each do |attr, errors|
          @note.errors.add(attr, errors)
        end
      end
      @note.from_address = @note.new_email_address
    end

    should_send_email = !@user.reload.is_guest?

    respond_to do |format|
      if @note.errors.empty? && @note.save
        log_event("Created Note")
        NoteMailer.delay.note_created(@note.id) if should_send_email
        format.html { redirect_to @note, notice: 'Note was successfully created.' }
        format.json { render json: @note, status: :created, location: @note }
      else
        format.html { render action: "new" }
        format.json { render json: @note.errors, status: :unprocessable_entity }
      end
    end
  end

  # PUT /notes/1
  # PUT /notes/1.json
  def update
    @note = Note.where(:id => params[:id], :user_id => current_or_guest_user.id).first

    respond_to do |format|
      if @note.update_attributes(params[:note])
        log_event("Updated Note")
        format.html { redirect_to @note, notice: 'Note was successfully updated.' }
        format.json { head :ok }
      else
        format.html { render action: "edit" }
        format.json { render json: @note.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /notes/1
  # DELETE /notes/1.json
  def destroy
    @note = Note.where(:id => params[:id], :user_id => current_or_guest_user.id).first
    @note.destroy
    log_event("Deleted Note")
    respond_to do |format|
      format.html { redirect_to notes_url }
      format.json { head :ok }
    end
  end

  def create_from_mailgun
    @note = Note.new

    from_address = parse_address
    user = User.find(UserEmail.find_by_email(from_address).user_id)
    if user.nil?
      render :status => :ok, :text => 'Rejected'
      return
    end

    @note.user_id = user.id

    if validate_mailgun_signature
      @note.title = params['subject']
      @note.body = params['stripped-text']
      @note.from_address = parse_address
    else
      render :status => :unprocessable_entity, :text => 'Invalid Signature'
      return
    end

    if @note.save
      log_event("Created Note from Email", {:distinct_id => user.unique_id})
      NoteMailer.delay.note_created(@note.id)
      render :status => :ok, :text => 'OK'
    else
      render json: @note.errors, status: :unprocessable_entity
    end
  end

  def update_from_mailgun
    if validate_mailgun_signature
      unique_id = parse_unique_from_address
      @note = Note.find_by_unique_id(unique_id)

      from_address = parse_address
      user_email = UserEmail.find_by_email(from_address)
      raise ActionController::RoutingError.new('Not Found') if user_email.nil?

      user = User.find(user_email.user_id)
      if user.nil?
        render :status => :ok, :text => 'Rejected'
        return
      end

      if @note.nil?
        raise ActionController::RoutingError.new('Not Found')
      end

      if @note.append_to_body(params['stripped-text'])
        log_event("Updated Note from Email", {:distinct_id => user.unique_id})
        render :status => :ok, :text => 'OK'
      else
        render json: @note.errors, status: :unprocessable_entity
      end
    else
      render :status => :unprocessable_entity, :text => 'Invalid Signature'      
    end
  end

  def parse_unique_from_address
    params['recipient'].split(/@/)[0].gsub('note-', '')
  end

  def parse_address
    params['from'].scan(/<(.+)>/)[0][0] rescue params['from']
  end

  def validate_mailgun_signature
    signature = params['signature']
    return false if signature.nil?

    test_signature = OpenSSL::HMAC.hexdigest(
      OpenSSL::Digest::Digest.new('sha256'),
      ENV['MAILGUN_API_KEY'],
      '%s%s' % [params['timestamp'], params['token']]
    )

    return signature == test_signature
  end

  def search
    @notes = Note.search(params['q']).where(:user_id => current_or_guest_user.id)
    @query = params['q']

    log_event("Searched")

    respond_to do |format|
      format.html # search.html.erb
      format.json { render json: @notes }
    end
  end

  def share
    @note = Note.where(:id => params[:id], :user_id => current_or_guest_user.id).first
    log_event("Shared")
    respond_to do |format|
      format.html
      format.json { head :ok }
    end
  end

  def append_view
    @note = Note.where(:id => params[:id], :user_id => current_or_guest_user.id).first
    respond_to do |format|
      format.html
      format.json { head :ok }
    end
  end

  def share_by_email
    @note = Note.where(:id => params[:id], :user_id => current_or_guest_user.id).first
    @note.share(params[:email])

    respond_to do |format|
      format.html { redirect_to @note, notice: "Shared note with #{params[:email]}" }
      format.json { head :ok }
    end
  end

  def unshare
    @note = Note.where(:id => params[:id], :user_id => current_or_guest_user.id).first
    @note.unshare
    log_event("Unshared")

    respond_to do |format|
      format.html { redirect_to @note, notice: "Removed sharing" }
      format.json { head :ok }
    end
  end

  def append
    @note = Note.where(:id => params[:id], :user_id => current_or_guest_user.id).first
    respond_to do |format|
      if @note.append_to_body(params[:body])
        log_event("Appended")
        format.html { redirect_to @note, notice: 'Note was successfully updated.' }
        format.json { head :ok }
      else
        format.html { render action: "edit" }
        format.json { render json: @note.errors, status: :unprocessable_entity }
      end
    end
  end

  def share_view
    @note = Note.where(:share_id => params[:share_id]).first

    respond_to do |format|
      format.html
      format.json { render json: @note }
    end
  end

  def export
    Delayed::Job.enqueue ExportJob.new(current_user.id)
    flash[:notice] = "Your export has started. You will receive an email at #{current_user.email} when it's finished."
    redirect_to :back
  end

end
