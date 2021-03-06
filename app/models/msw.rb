# frozen_string_literal: true

class Msw < Forecast
  def avg_height
    (min_height + max_height) / 2
  end

  class << self
    def site_url
      'http://magicseaweed.com'
    end

    def api_url(spot)
      raise "No MagicSeaweed spot associated with #{spot.name} (#{spot.id})" if spot.msw_id.blank?

      "http://magicseaweed.com/api/#{ENV['MSW_API_KEY']}/forecast?spot_id=#{spot.msw_id}&units=us&fields=timestamp,solidRating,fadedRating,swell.absMinBreakingHeight,swell.absMaxBreakingHeight,swell.absHeight"
    end

    def for_chart
      pluck('round(min_height, 1)', 'round(max_height, 1)')
    end

    def parse_data(spot, request, data)
      data.each do |entry|
        tstamp = Time.zone.at(entry.timestamp)
        # Adjust for weird shifts in California timestamps
        if spot.subregion.timezone == 'Pacific Time (US & Canada)' && (offset = tstamp.hour % 3) != 0
          tstamp += (3 - offset).hour
        end
        record = unscoped.where(spot: spot, timestamp: tstamp).first_or_initialize
        record.api_request = request
        record.min_height = entry.swell.absMinBreakingHeight || entry.swell.absHeight
        record.max_height = entry.swell.absMaxBreakingHeight || entry.swell.absHeight
        record.rating = entry.solidRating
        record.wind_effect = entry.fadedRating
        record.save! if record.rating.present?
      end
    end
  end
end
