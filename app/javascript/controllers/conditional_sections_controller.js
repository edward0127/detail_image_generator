import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    sourceAttribute: String,
    sectionAttribute: String,
    disableHidden: { type: Boolean, default: false }
  }

  connect() {
    this.update()
  }

  update() {
    const source = this.sourceElement

    if (!source) return

    this.sections.forEach((section) => {
      const visible = this.sectionMatches(section, source.value)

      section.hidden = !visible
      if (this.disableHiddenValue) this.setControlsDisabled(section, !visible)
    })
  }

  get sourceElement() {
    const selector = this.dataSelector(this.sourceAttributeValue)

    if (selector) {
      return this.element.querySelector(selector)
    }

    return this.element.querySelector("select, input, textarea")
  }

  get sections() {
    const selector = this.dataSelector(this.sectionAttributeValue)

    if (!selector) return []

    return Array.from(this.element.querySelectorAll(selector))
  }

  sectionMatches(section, value) {
    const sectionValue = section.getAttribute(this.dataAttributeName(this.sectionAttributeValue))
    const values = sectionValue.toString().split(/[\s,]+/).filter(Boolean)

    return values.includes(value)
  }

  setControlsDisabled(section, disabled) {
    section.querySelectorAll("input, select, textarea, button").forEach((control) => {
      control.disabled = disabled
    })
  }

  dataSelector(attributeName) {
    if (!attributeName) return null

    return `[${this.dataAttributeName(attributeName)}]`
  }

  dataAttributeName(attributeName) {
    return attributeName.startsWith("data-") ? attributeName : `data-${attributeName}`
  }

}
