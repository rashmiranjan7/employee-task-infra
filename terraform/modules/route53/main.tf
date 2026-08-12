# The hosted zone already exists — the domain is registered elsewhere
# (GoDaddy) with its nameservers already pointed at Route53. Terraform looks
# it up instead of creating one, so there's no risk of Terraform ever trying
# to manage (or delete) a zone that DNS delegation depends on.
data "aws_route53_zone" "this" {
  name = var.domain_name
}
