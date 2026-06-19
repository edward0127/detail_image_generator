import "controllers"

const localTimeFormatOptions = {
  day: "2-digit",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
  timeZoneName: "shortOffset"
}

let localTimeFormatter

function buildLocalTimeFormatter() {
  try {
    return new Intl.DateTimeFormat(undefined, localTimeFormatOptions)
  } catch (error) {
    return new Intl.DateTimeFormat(undefined, {
      ...localTimeFormatOptions,
      timeZoneName: "short"
    })
  }
}

function getLocalTimeFormatter() {
  localTimeFormatter ||= buildLocalTimeFormatter()
  return localTimeFormatter
}

function formatLocalTime(value, placeholder = "not started") {
  if (!value) {
    return placeholder
  }

  const date = new Date(value)
  if (Number.isNaN(date.getTime())) {
    return value
  }

  const parts = getLocalTimeFormatter().formatToParts(date).reduce((memo, part) => {
    if (part.type !== "literal") {
      memo[part.type] = part.value
    }
    return memo
  }, {})

  const time = [parts.hour, parts.minute].filter(Boolean).join(":")
  return [parts.day, parts.month, time, parts.timeZoneName].filter(Boolean).join(" ")
}

function applyLocalTimes(root = document) {
  root.querySelectorAll("[data-local-time][datetime]").forEach((element) => {
    const utcValue = element.getAttribute("datetime")
    element.textContent = formatLocalTime(utcValue, element.textContent)
  })
}

window.DetailImageGenerator = window.DetailImageGenerator || {}
window.DetailImageGenerator.formatLocalTime = formatLocalTime
window.DetailImageGenerator.applyLocalTimes = applyLocalTimes

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => applyLocalTimes())
} else {
  applyLocalTimes()
}

document.addEventListener("turbo:load", () => applyLocalTimes())
