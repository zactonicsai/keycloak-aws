# =============================================================================
# KMS MODULE - variables.tf
# =============================================================================

variable "name_prefix" {
  description = "Prefix glued onto key aliases and tags"
  type        = string
}

variable "deletion_window_in_days" {
  description = "Grace period before a deleted KMS key is destroyed forever (7-30 days)"
  type        = number
  default     = 30

  validation {
    # AWS hard-limits this range. Catching it here gives a clearer error
    # than waiting for the API to reject it halfway through an apply.
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30."
  }
}

variable "tags" {
  description = "Labels applied to both KMS keys"
  type        = map(string)
  default     = {}
}
