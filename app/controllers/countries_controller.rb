class CountriesController < ApplicationController
  before_action :check_for_admin, only: [:edit]
  before_action :check_for_admin, only: [:new]
  before_action :check_for_admin, only: [:destroy]
  before_action :original_url, only: [:index]

  def index
    @countries = Country.includes(:sanctions).select { |c| c.sanctions.size > 0 }
    @countries = @countries.sort_by { |c| c.name }
    @all_countries = Country.all
  end

  def new
    @country = Country.new
  end

  def create
    @country = Country.new country_params
    @country.name = titleize(@country.name)
    @country.save
    if @country.save
      redirect_to @country
    else
      render :new
    end
  end

  def edit
    @country = Country.find params[:id]
  end

  def update
    @country = Country.find params[:id]
    previous_name = @country.name
    @country.assign_attributes country_params
    @country.name = titleize(@country.name)
    begin
      if @country.flag.present? && !(@country.flag.include? 'cloudinary')
        req = Cloudinary::Uploader.upload(@country.flag)
        @country.flag = req['secure_url']
        @country.save
      end
    rescue StandardError
      @country.save
    end
    unless @country.name != previous_name && Country.find_by(name: @country.name).present?
      @country.save
      @country.sanctions.each do |sanction|
        sanction.nationality = @country.name
        sanction.save
      end
    end
    if @country.save
      redirect_to @country
    else
      render :edit
    end
  end

  def destroy
    country = Country.find params[:id]
    country.destroy
    redirect_to countries_path
  end

  def show
    unless params[:id].to_i > 0
      if Country.find_by(country_code: params[:id].upcase).nil?
        begin
          intended_country = ISO3166::Country.find_country_by_alpha2(params[:id]).unofficial_names[0]
        rescue StandardError
          intended_country = 'that country'
        end
        redirect_to countries_path,
                    alert: "Seems that none of our users have put any sanctions on #{intended_country} yet, why not start sanctioning people* from there now?"
        return

      elsif Country.find_by(country_code: params[:id].upcase).sanctions.size == 0

        intended_country = Country.find_by(country_code: params[:id].upcase).name

        redirect_to countries_path,
                    alert: "Seems that none of our users have put any sanctions on #{intended_country} yet, why not start sanctioning people* from there now?"
        return
      else
        params[:id] = Country.find_by(country_code: params[:id].upcase).id
      end
    end

    @country = Country.find params[:id]
    sanctions = Sanction.where(nationality: @country.name)
    if @country.sanctions.size != sanctions.size
      sanctions.each do |sanction|
        @country.sanctions << sanction
      end
    end

    if @country.official_name == '' || @country.official_name.nil?
      @country.official_name = (country_info @country.name)[:official_name]
      @country.save
    end
    if @country.native_name == '' || @country.native_name.nil?
      @country.native_name = (country_info @country.name)[:native_name]
      @country.save
    end
    if @country.flag == '' || @country.flag.nil?
      @country.flag = (country_info @country.name)[:flag]
      @country.save
    end

    if @country.country_code == '' || @country.country_code.nil?
      @country.country_code = (country_info @country.name)[:country_code]
      @country.save
    end

    return if @country.name == 'Unknown'

    if @country.description.nil?
      your_cse_id = 'e3218dc0a18944649' # www.google.com
      # your_cse_id = '57c3cb0530b3d4750' # www.google.com/imghp?hl=EN*
      wiki_search = "https://www.googleapis.com/customsearch/v1?key=#{your_api_key}&cx=#{your_cse_id}&q=#{@country.name.gsub(' ', '%20').gsub(
        ',', '%20'
      )}%20wikipedia"
      wiki_results = HTTParty.get wiki_search
      begin
        wiki_url = wiki_results['items'][0]['link']
        wiki = wiki_url[wiki_url.index('/wiki/') + 6..]
        dbpedia_url = "https://dbpedia.org/page/#{wiki}"
        dbpedia_doc = Nokogiri::HTML(URI.open(dbpedia_url))
        result = dbpedia_doc.search('span[property="dbo:abstract"][lang="en"]')
        @country_info = result.first.text
        @country.description = @country_info
        @country.save
      rescue StandardError
        @country_info = 'Not Available'
      end
    else
      @country_info = @country.description
    end
    @cia_factbook = {}
    filename = File.dirname(File.expand_path('..', __dir__)) + '/data/cia_factbook.csv'
    CSV.foreach(filename, headers: true, header_converters: :symbol, converters: :all) do |row|
      @cia_factbook[row.fields[0]] = Hash[row.headers[1..-1].zip(row.fields[1..-1])]
    end
    search = "#{@country.name} anthem"
    api_video_results = "https://www.googleapis.com/youtube/v3/search?key=#{your_api_key}&q=#{search}&type=video&part=snippet"
    video_results = HTTParty.get api_video_results
    @video = if !video_results.to_s.include?('error')
               'https://www.youtube.com/embed/' + video_results['items'][0]['id']['videoId']
             else
               video_results

             end
  end

  def sanctions
    params[:id] = Country.find_by(country_code: params[:id]).id unless params[:id].to_i > 0
    @country = Country.find params[:id]
    @sanctions = @country.sanctions.order(:name)
  end

  private

  def original_url
    @referer = request.path
  end

  def titleize(str)
    str.split(/ |_/).map(&:capitalize).join(' ')
  end

  def country_params
    params.require(:country).permit(:name, :official_name, :native_name, :country_code, :flag, :description)
  end

  def country_info(country_name)
    country_info = { official_name: nil, native_name: nil, country_code: nil, flag: nil }
    begin
      country_url = "https://restcountries.com/v3.1/name/#{country_name.gsub(' ', '%20')}?fullText=true"
      country_details = HTTParty.get country_url
      country_info[:official_name] = country_details[0]['name']['official']
      native_name_list = country_details[0]['name']['nativeName'].flatten
      native_name_list = native_name_list.drop(2) if native_name_list[0] == 'eng' && native_name_list.length > 2
      country_info[:native_name] = native_name_list[1]['official']
      country_info[:country_code] = country_details[0]['cca2']
      country_info[:flag] = country_details[0]['flags']['png']
    rescue StandardError
      begin
        country_details = ISO3166::Country.find_country_by_any_name(country_name)
        country_info[:official_name] = country_details.iso_long_name
        country_info[:country_code] = country_details.alpha2
      rescue StandardError
      end
    end

    country_info
  end
end
