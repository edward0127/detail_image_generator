import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "input", "submit" ]
  static values = {
    projectName: String
  }

  connect() {
    this.check()
  }

  check() {
    if (!this.hasInputTarget || !this.hasSubmitTarget) return

    this.submitTarget.disabled = this.inputTarget.value !== this.projectNameValue
  }
}
