# spec 057 round 2 Q4 A: a monthly budget alert on the satellite, applied
# BEFORE the VM (060). Scoped to csi-spl-all AND the satellite's label, so
# nothing else billed to the account trips it. Alerts mail the billing
# account's admins (the default IAM recipients); nothing is ever stopped.
data "google_project" "this" {
  project_id = var.gcp_project
}

resource "google_billing_budget" "satellite" {
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
}
