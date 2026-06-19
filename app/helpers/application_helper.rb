module ApplicationHelper
  LOCAL_TIME_FALLBACK_FORMAT = "%d %b %H:%M UTC"

  def local_time_tag(time, placeholder: "not started", always_time: false, **options)
    data_options = options.delete(:data) || {}

    if time.blank?
      blank_options = options.merge(data: data_options)
      return always_time ? tag.time(placeholder, **blank_options) : tag.span(placeholder, **blank_options)
    end

    utc_time = time.to_time.utc
    iso8601 = utc_time.iso8601
    fallback = utc_time.strftime(LOCAL_TIME_FALLBACK_FORMAT)
    title = options.key?(:title) ? options.delete(:title) : "UTC: #{iso8601}"

    tag.time(
      fallback,
      **options.merge(
        datetime: iso8601,
        title: title,
        data: data_options.merge(local_time: true)
      )
    )
  end
end
