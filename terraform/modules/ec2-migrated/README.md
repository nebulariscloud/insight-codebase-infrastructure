# Module: ec2-migrated

EC2 instance for lift-and-shift migrations. Replaces the commented `migrated-ec2.yaml` example shape.

Defaults:

- IMDSv2 required
- EBS-optimized, gp3 root volume, encrypted at rest
- Detailed monitoring on
- Termination protection on
- `EC2-Default-SSM-Role` instance profile attached (provisioned by LZA in every spoke)
- `lifecycle.ignore_changes = [ami, user_data]` so routine AMI rotation doesn't accidentally replace the instance — change AMI explicitly when you mean to

## Usage

```hcl
module "alfresco" {
  source = "../../../modules/ec2-migrated"

  name          = "alfresco-prod"
  ami_id        = "ami-0eef1ec163e0fc571"
  instance_type = "m5.large"
  vpc_id        = data.aws_ssm_parameter.vpc_id.value
  subnet_id     = data.aws_ssm_parameter.app_subnet_a.value
  private_ip    = "10.12.4.50"

  ingress_rules = [
    { from_port = 8080, to_port = 8080, protocol = "tcp", cidr_blocks = ["10.0.0.0/8"], description = "App from VPC" },
  ]

  additional_ebs_volumes = [
    { device_name = "/dev/sdf", size = 500, type = "gp3", snapshot_id = "snap-..." }
  ]

  route53 = {
    hosted_zone_id = "Zxxxxx"
    record_name    = "alfresco.internal.example.com"
  }

  tags = { App = "alfresco" }
}
```

## When NOT to use this

- Building net-new horizontal apps. Use ECS, ASG with launch templates, or another module.
- Anything in PCI scope without auditing the security group rules and disk encryption settings.
