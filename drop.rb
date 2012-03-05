require 'rubygems'
require 'dropbox'
require 'sinatra'
require 'mongo'
require 'haml'
require 'nokogiri'
require 'mechanize'
require 'net/imap'
require 'net/smtp'
require 'tmail'
require 'pony'
ruby_version = /([0-9]+)\.([0-9]+)\.([0-9]+)/.match(`ruby -v`)
if ruby_version[1].to_i <= 1 and ruby_version[2].to_i <= 8 and
ruby_version[3].to_i <= 6
  require "smtp_tls"
end

Mechanize.html_parser = Nokogiri::HTML

def send_mail(message,to)
=begin
msgstr = <<END_OF_MESSAGE
From: "Twitter Bot" <saketkc@gmail.com>
To: #{to} <testuser>
Subject: SomeBody sent you a file from DropBox

#{message}
END_OF_MESSAGE

	smtp = Net::SMTP.new('smtp.gmail.com',587)
    smtp.enable_starttls
 	smtp.start("gmail.com","saketkc","fedora13",:login) do
      smtp.send_message(msgstr,to,to)
	end

Pony.mail (:to => to ,:via => :smtp, :via_options =>{
  :address   => 'smtp.gmail.com',
  :port   => '587',
  :tls    => true,
  :user_name   => 'saketkc',
  :password   => 'fedora13',
  :authentication   => :login, # :plain, :login, :cram_md5, no auth by default
  :domain => "localhost.localdomain" # the HELO domain provided by the client to the server
})	
=end
Pony.mail(:to => "kcsaket@gmail.com",
              :from => "saketkc@gmail.com",
              :subject =>  "DropBox Document",
              :body =>"ASDAS",
              :via => :smtp,
             :via_options =>{
                  :address              => 'smtp.gmail.com',
                  :port                 => '587',
                  :user_name                 => "saketkc@gmail.com",
                  :enable_starttls_auto => true, 
                  :password             => "fedora13",
                  :authentication       => :plain,# :plain, :login, :cram_md5, no auth by default
                  :domain => "localhiost.local"
                                })
end

class DropBox 	
	def initialize(email, password, folder_namespace = "")
		@email = email
		@password = password
		@agent = Mechanize.new
		@folder_namespace = folder_namespace.gsub(/^\//,"")
		@logged_in = false
	end
	
	def agent
	  @agent
     end
	
	# Lists all the files and folders in a given directory
	 def index(path = "/")
 		login_filter
		path = namespace_path(path)
		
		list = @agent.post("/browse2#{path}?ajax=yes", {"d"=> 1, "t" => @token })
		
		listing = list.search('div.browse-file-box-details').collect do |file|
			details = {}
			details['name'] = file.at('div.details-filename a').content.strip
			details['url']  = file.at('div.details-filename a')["href"]
			#details['size'] = file.at('div.details-size a').try(:content).try(:strip)
			#details['modified'] = file.at('div.details-modified a').try(:content).try(:strip)
			
			if match_data = details['url'].match(/^\/browse_plain(.*)$/)
				details['directory'] = true
				details['path'] = normalize_namespace(match_data[1])
			elsif match_data = details['url'].match(%r{^https?://[^/]*/get(.*)$})
				details['directory'] = false
				details['path'] = normalize_namespace(match_data[1])
      elsif match_data = details['url'].match(%r{^https?://[^/]*/u/\d*/(.*)$})
          details['directory'] = false
          details['path'] = "Public/#{match_data[1]}"
			else
				raise "could not parse path from Dropbox URL: #{details['url'] }"
			end
			
			details
		end
		#

		return listing
	end
	
	alias :list :index
	
	# Lists the full history for a file on DropBox
	def list_history(path)
		login_filter
		
		path = namespace_path(path)

		history = @agent.get("/revisions#{path}")
		listing = history.search("table.filebrowser > tr").select{|r| r.search("td").count > 1 }.collect do |r|
			
			# warning, this is very brittle!
			details = {}
			details["version"] = r.search("td a").first.content.strip
			details["url"] = r.search("td a").first["href"]
			details["size"] = r.search("td").last.content.strip
			details["modified"] = r.search("td")[2].content.strip
			details["version_id"] = details["url"].match(/^.*sjid=([\d]*)$/)[1]
			details['path'] = normalize_namespace(details['url'][33..-1])
			
			details
		end
		
		return listing
	end
	
	# Downloads the specified file from DropBox
	def show(path)
	  require 'pathname'
		# change to before filter
		login_filter
		
		# round about way of getting the secure url we need
    # path = namespace_path(path)
		pathname = Pathname.new(path)
		url = self.list(pathname.dirname.to_s).detect{ |f| f["name"] == pathname.basename.to_s }["url"]
		
		#https://dl-web.dropbox.com/get/testing.txt?w=0ff80d5d&sjid=125987568
		@content=@agent.get(url).content
	end
	
	alias :get :show
	
	# Creates a directory
	def create_directory(new_path, destination = "/" )
		# change to before filter
		login unless @logged_in
		destination = namespace_path(destination)
		@agent.post("/cmd/new#{destination}",{"to_path"=>new_path, "folder"=>"yes", "t" => @token }).code == "200"
	end
	
	# Uploads a file to DropBox under the given filename
	def create(file, destination = "/")
		# change to before filter
		if @logged_in
			home_page = @agent.get('https://www.dropbox.com/home')
		else
			home_page = login
		end
		
		upload_form = home_page.forms.detect{ |f| f.action == "https://dl-web.dropbox.com/upload" }
		upload_form.dest = namespace_path(destination)
		upload_form.file_uploads.first.file_name = file if file
		
		@agent.submit(upload_form).code == "200"
	end
	
  alias :update :create
	
	# Renames a file or folder in the DropBox
	def rename(file, destination)
		login_filter
		file = namespace_path(file)
		destination = namespace_path(destination)
		@agent.post("/cmd/rename#{file}", {"to_path"=> destination, "t" => @token }).code == "200"
	end
	
	# Deletes a file/folder from the DropBox (accepts string path or an array of string paths)
	def destroy(paths)
		login_filter
		paths = [paths].flatten
		paths = paths.collect { |path| namespace_path(path) }
		@agent.post("/cmd/delete", {"files"=> paths, "t" => @token }).code == "200"
	end

  # Permanently deletes a file from the DropBox (no history!) accepts arrays, as #destroy does
	def purge(paths)
		login_filter
		paths = [paths].flatten
		paths = paths.collect { |path| namespace_path(path) }
		@agent.post("/cmd/purge", {"files"=> paths, "t" => @token }).code == "200"
	end
	
	# Will give a hash of the amount of space left on the DropBox, the amound used, the calculated amount free (all as a 1 d.p. rounded GB value) and the percentage used (scraped)
	def usage_stats
	  login_filter
    
	  stats_page = @agent.get("/account")
	  
	  stats = stats_page.at('#usage-percent').content.scan(/(\d+(?:\.\d+)?)%\ used\ \((\d+(?:\.\d+)?)([MG])B of (\d+(?:\.\d+)?)GB\)/).collect{ |d|
	    { :used => d[1].to_f * ((d[2] == "G") ? 1024 : 1),
	      :total => d[3].to_f * 1024,
	      :free => (d[3].to_f * 1024 - d[1].to_f * ((d[2] == "G") ? 1024 : 1)),
	      :percent => Percentage.new(d[0].to_f/100)
	    }
	  }[0]
	  
	  regular_data = stats_page.at('span.bar-graph-legend.bar-graph-normal').next.content.scan(/\((\d+(?:\.\d+)?)([MG])B/)[0]
	  stats[:regular_used] = regular_data[0].to_f * ((regular_data[1] == "G") ? 1024 : 1) unless regular_data.nil?

	  shared_data = stats_page.at('span.bar-graph-legend.bar-graph-shared').next.content.scan(/\((\d+(?:\.\d+)?)([MG])B/)[0]
	  stats[:shared_used] = shared_data[0].to_f * ((shared_data[1] == "G") ? 1024 : 1) unless shared_data.nil?

    return stats
  end

	private
	def namespace_path(path)
		# remove the start slash if we have one
		path.gsub(/^\//,"")
		new_path = if @folder_namespace.empty?
			"/#{path}"
		else
			"/#{@folder_namespace}/#{path}"
		end
		new_path.gsub("//","/")
	end
	
	def normalize_namespace(file)
		file.gsub(/^\/#{@folder_namespace}/,"")
	end

  def login
		page = @agent.get('https://www.dropbox.com/login')
		login_form = page.forms.detect { |f| f.action == "/login" }
		login_form.login_email = @email
		login_form.login_password = @password
		
		home_page = @agent.submit(login_form)
		# todo check if we are logged in! (ie search for email and "Log out"
		@logged_in = true
		@token = home_page.at('//script[contains(text(), "TOKEN")]').content.match("TOKEN: '(.*)',$")[1]
		
		# check if we have our namespace
		
		home_page
	end
	
	def login_filter
		login unless @logged_in
	end
end

get "/" do  
  db = Mongo::Connection.new("staff.mongohq.com", 10007).db("dropbox_data")
  auth = db.authenticate("saket", "fedora")
  coll = db.collection("dropbox_collections")
  @txtweb_message=params["txtweb-message"] .to_s
  if @txtweb_message == ""
    "The general format of the commands is  {dropbox_username:dropbox_password:COMMAND:path}"+
    "\nCommands : sendsss => send file, delete => delete file, list => list files, path = path of the file"   
  else  
     if @txtweb_message.scan(/:/) == []
       my_doc = coll.find_one({"number" => params["txtweb-mobile"].to_s, "command" => "send"})
       #unless my_doc
        # "The general format of the commands is  {dropbox_username:dropbox_password:COMMAND:path}"+
        #"\nCommands : send => send file, delete => delete file, list => list files, path = path of the file" 
       #else
        @to_user = params["txtweb-message"].to_s
        @file_path = my_doc["filepath"]
         authorize = DropBox.new(my_doc["username"],my_doc["secret"])
        message = authorize.show(@file_path)
        send_mail(message.to_s,@to_user.to_s+"@gmail.com")
        coll.remove({"number" => params["txtweb-mobile"].to_s})
        "File emailed successfully"
      #end
    else
        @msg =   @txtweb_message.split(/:/)
        @username = @msg[0].to_s + "@gmail.com"
        @password = @msg[1].to_s
        @command = @msg[2].to_s || "list"
        @path = @msg[3].to_s || "/"
        
        authorize = DropBox.new(@username,@password)
        if @command == "send"
           doc = {"number" => params["txtweb-mobile"], "command" => "send", "username" => @username,  "secret" =>   @password , "filepath"=>@path }
            coll.insert(doc)    
            "Reply with users email address"
        elsif @command == "delete"
            authorize.destroy(@path) 
            "File Deleted"
        elsif @command == "list"    
          #puts "#{authorize.index(@path')}"
          "#{authorize.index(@path)}"
          #b=a.gsub(/directorytrueurl\/browse_plain/,"")
          #"#{b}"
          elsif @command == "history"
             "#{authorize.list_history(@path)}"
        end
        
    end
   
  end
  
end
