# Marketplace validation requires this file at the zip root; the stack uses no Marketplace images.
variable "marketplace_source_images" {
  type = map(object({
    ocid                  = string
    is_pricing_associated = bool
    compatible_shapes     = set(string)
  }))
  default = {}
}
