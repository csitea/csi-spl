# The revision name 030 sends with the hub's template (SPL-4298). Pure logic,
# no provider, so revision-name-030.tst.sh drives it offline.
#
# Provider google 6.50.0 (the step's lock): template.revision is Optional and
# not Computed, and an update PATCHes the whole template, revision included.
# Cloud Run refuses a known revision name with another configuration (409
# "Revision named ... with different configuration already exists").
#   - unchanged: terraform's inputs (the label) and the plain env match the
#     live template -> send the live name, which the 20 pipeline (gcloud)
#     chose, so the plan holds no revision diff (SPL-3997)
#   - changed: a fresh name, from the live name and the new inputs hash, so
#     it never repeats a name Cloud Run already holds and stays the same on
#     every plan until it is applied
variable "service_name" {
  type        = string
  description = "The Cloud Run service; a revision name must start with it and a dash."

  validation {
    condition     = length(var.service_name) <= 51
    error_message = "service_name must be at most 51 characters: <service>-tf-<8 hex> fits Cloud Run's 63."
  }
}

variable "template_hash" {
  type        = string
  description = "The hash of every template input terraform owns (the image excluded: the 20 pipeline owns it)."
}

variable "live_revision" {
  type        = string
  description = "template.revision of the live service, \"\" when it has none or does not exist yet."
}

variable "live_template_hash" {
  type        = string
  description = "The template label the last apply wrote, \"\" when there is none."
}

variable "live_env" {
  type        = map(string)
  description = "The live template's plain env (name -> value)."
}

variable "want_env" {
  type        = map(string)
  description = "The plain env terraform applies."
}

locals {
  unchanged = var.live_template_hash == var.template_hash && var.live_env == var.want_env
  fresh     = "${var.service_name}-tf-${substr(sha1("${var.live_revision}|${var.template_hash}"), 0, 8)}"
}

output "label_key" {
  description = "The template label that carries template_hash."
  value       = "tf-template"
}

output "revision" {
  description = "template.revision to send: the live name when nothing changed (null when it has none), else a fresh one."
  value       = local.unchanged ? (var.live_revision == "" ? null : var.live_revision) : local.fresh
}
