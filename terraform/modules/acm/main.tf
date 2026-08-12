resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = var.domain_name
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.route53_zone_id
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]

  # 20m, not 10m: the dependency chain here (validation -> record ->
  # certificate) is already correct — Terraform won't even attempt
  # validation before the Route53 record exists. The failure mode this
  # guards against is slow DNS propagation on the registrar's side, which
  # can occasionally exceed 10 minutes and looks exactly like a stuck
  # Terraform apply. See PREREQUISITES.md for the dig-based check to run
  # BEFORE applying this module, which catches most of these cases earlier
  # and faster than waiting out this timeout.
  timeouts {
    create = "20m"
  }
}
