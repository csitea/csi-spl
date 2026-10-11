# A monthly budget alert for the wine-box label, applied BEFORE the VM (061).
# Scoped to this project AND that label, so the rest of the project does not
# trip it. Alerts mail the billing account's admins. Nothing is stopped.
resource "google_project_service" "budget_api" {
  project                    = var.gcp_project
  service                    = var.budget_api
  disable_on_destroy         = false
  disable_dependent_services = false
}

data "google_project" "this" {
  project_id = var.gcp_project
}

resource "google_billing_budget" "wine_box" {
  billing_account = var.billing_account_id
  display_name    = var.budget_display_name

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
    labels = {
      (var.budget_label_key) = var.budget_label_value
    }
  }

  # no currency_code: the amount is in the billing account's currency, and
  # naming another one is a 400
  amount {
    specified_amount {
      units = tostring(var.budget_amount_month)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.threshold_percents
    content {
      threshold_percent = threshold_rules.value
    }
  }

  depends_on = [google_project_service.budget_api]
}
