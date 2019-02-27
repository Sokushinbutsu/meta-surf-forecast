# frozen_string_literal: true

class Surfline < Forecast
  self.abstract_class = true

  scope :with_rating_and_wind, -> { where.not(swell_rating: nil).where.not(optimal_wind: nil) }

  def display_swell_rating
    (swell_rating * 5 * wind_factor).round unless swell_rating.nil? || optimal_wind.nil?
  end

  def wind_factor
    optimal_wind ? 1 : 0.5
  end

  def avg_height
    (min_height + max_height) / 2
  end

  class << self
    def default_scope
      super.with_rating_and_wind
    end

    def site_url
      'http://www.surfline.com'
    end

    def api_url(spot, use_nearshore = true, get_all_spots = true)
      raise "No Surfline spot associated with #{spot.name} (#{spot.id})" if spot.surfline_id.blank?

      "http://api.surfline.com/v1/forecasts/#{spot.surfline_id}?resources=surf,wind,sort&days=#{num_days}&getAllSpots=#{get_all_spots}&units=e&interpolate=true&showOptimal=true&usenearshore=#{use_nearshore}"
    end

    def for_chart
      pluck('round(min_height, 1)', 'round(max_height, 1)')
    end

    def parse_response(spot, request, responses)
      # If get_all_spots is false, response will be a single object instead of an array
      responses = [responses] unless responses.is_a? Array
      forecasts = {}
      zone = ActiveSupport::TimeZone.new(spot.subregion.timezone)

      responses.each do |response|
        spot_id = response.id
        forecasts[spot_id] ||= {}
        response.Surf.dateStamp.each_with_index do |day, day_index|
          day.each_with_index do |timestamp, timestamp_index|
            tstamp = zone.parse(timestamp)
            forecasts[spot_id][tstamp] ||= {}
            forecasts[spot_id][tstamp][:min_height] = response.Surf.surf_min[day_index][timestamp_index]
            forecasts[spot_id][tstamp][:max_height] = response.Surf.surf_max[day_index][timestamp_index]
          end
        end

        response.Sort.dateStamp.each_with_index do |day, day_index|
          day.each_with_index do |timestamp, timestamp_index|
            tstamp = zone.parse(timestamp)
            forecasts[spot_id][tstamp] ||= {}
            max_swell_rating = 0
            (1..6).each do |swell_index|
              max_swell_rating = [max_swell_rating, response.Sort["optimal#{swell_index}"][day_index][timestamp_index].to_d].max
            end
            forecasts[spot_id][tstamp][:swell_rating] = max_swell_rating
          end
        end

        response.Wind.dateStamp.each_with_index do |day, day_index|
          day.each_with_index do |timestamp, timestamp_index|
            tstamp = zone.parse(timestamp)
            forecasts[spot_id][tstamp] ||= {}
            forecasts[spot_id][tstamp][:optimal_wind] = response.Wind.optimalWind[day_index][timestamp_index]
          end
        end
      end

      # Fill in blanks in swell ratings by averaging previous & next ratings
      forecasts.each_key do |spot_id|
        spot_data = forecasts[spot_id]
        # [1..-2] gets all elements except first & last
        spot_data.keys[1..-2].each_with_index do |tstamp, index|
          next if spot_data[:swell_rating].present?

          prev_tstamp = spot_data.keys[index] # index is already offset by 1
          next_tstamp = spot_data.keys[index + 2]
          prev_rating = spot_data[prev_tstamp][:swell_rating]
          next_rating = spot_data[next_tstamp][:swell_rating]
          forecasts[spot_id][tstamp][:swell_rating] = (prev_rating + next_rating) / 2 if prev_rating && next_rating
        end
      end

      forecasts.each do |surfline_id, timestamps|
        next unless (spot = Spot.find_by(surfline_id: surfline_id))

        timestamps.each do |timestamp, values|
          # Adjust for weird shifts in California timestamps
          if zone.name == 'Pacific Time (US & Canada)' && (offset = timestamp.utc.hour % 3) != 0
            timestamp += (3 - offset).hour
          end
          record = unscoped.where(spot_id: spot.id, timestamp: timestamp).first_or_initialize
          record.api_request = request
          values.each do |attribute, value|
            record[attribute] = value
          end
          record.save! if record.swell_rating.present?
        end
      end
    end

  private

    def num_days
      ENV['SURFLINE_DAYS'] || 15
    end
  end
end
