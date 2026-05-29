variable "name" {
  description = "Server name. Used for the Name tag and resource names."
  type        = string
}

variable "ami_id" {
  description = "AMI ID. For lift-and-shift migrations this is your copied AMI in the destination region."
  type        = string
  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must look like ami-xxxxxxxx."
  }
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "m5.large"
}

variable "subnet_id" {
  description = "Subnet ID. Read from /accelerator/network/vpc/<vpc>/subnet/<subnet>/id."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID. Used by the security group."
  type        = string
}

variable "private_ip" {
  description = "Optional static private IP. Empty = let AWS pick."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name. Empty = SSM-only access (recommended)."
  type        = string
  default     = ""
}

variable "iam_instance_profile" {
  description = "IAM instance profile name. Empty = none. LZA provisions 'EC2-Default-SSM-Role' in every spoke."
  type        = string
  default     = "EC2-Default-SSM-Role"
}

variable "ingress_rules" {
  description = "Inbound rules for the instance security group."
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
    description = string
  }))
  default = []
}

variable "additional_security_group_ids" {
  description = "Extra security groups attached to the instance, in addition to the one created here."
  type        = list(string)
  default     = []
}

variable "root_volume_size" {
  description = "Root volume size in GiB. Most migrated AMIs ship the original size."
  type        = number
  default     = 100
}

variable "root_volume_type" {
  description = "Root volume type."
  type        = string
  default     = "gp3"
}

variable "root_volume_kms_key_id" {
  description = "KMS key ID/ARN for root volume encryption. Empty = AWS-managed default EBS key."
  type        = string
  default     = ""
}

variable "additional_ebs_volumes" {
  description = "Extra EBS volumes attached at known device names. Useful when restoring multi-volume snapshots."
  type = list(object({
    device_name = string
    size        = number
    type        = string
    iops        = optional(number)
    throughput  = optional(number)
    snapshot_id = optional(string)
    kms_key_id  = optional(string)
  }))
  default = []
}

variable "user_data" {
  description = "User data script. For most migrated AMIs leave empty - the OS image already has its config."
  type        = string
  default     = ""
}

variable "imdsv2_required" {
  description = "Require IMDSv2. Strongly recommended."
  type        = bool
  default     = true
}

variable "monitoring" {
  description = "Detailed CloudWatch monitoring (1-minute metrics)."
  type        = bool
  default     = true
}

variable "ebs_optimized" {
  description = "EBS-optimized."
  type        = bool
  default     = true
}

variable "disable_api_termination" {
  description = "Termination protection."
  type        = bool
  default     = true
}

variable "allocate_eip" {
  description = "Allocate and associate an Elastic IP."
  type        = bool
  default     = false
}

variable "route53" {
  description = "Optional Route53 record. Set hosted_zone_id and record_name to create an A record pointing at the instance's primary private IP (or EIP if allocated)."
  type = object({
    hosted_zone_id = string
    record_name    = string
    ttl            = optional(number, 300)
    use_public_ip  = optional(bool, false)
  })
  default = null
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
