# OCI 인증 (API key)
variable "tenancy_ocid" {
  description = "OCI tenancy OCID"
  type        = string
}

variable "user_ocid" {
  description = "API key 소유 user OCID"
  type        = string
}

variable "fingerprint" {
  description = "API key fingerprint"
  type        = string
}

variable "private_key_path" {
  description = "API key private key 로컬 경로"
  type        = string
}

variable "region" {
  description = "OCI region (예: ap-seoul-1, ap-tokyo-1)"
  type        = string
}

# 배치
variable "compartment_ocid" {
  description = "리소스 컴파트먼트 OCID"
  type        = string
}

# 인스턴스 접근
variable "ssh_public_key" {
  description = "인스턴스 SSH 공개키"
  type        = string
}

variable "my_home_ip_cidr" {
  description = "본인 home IP /32 — SSH fallback (L8)"
  type        = string
}

# 부트 볼륨 크기 (목표값)
variable "ops_vm_boot_size" {
  description = "ops-vm boot volume GB"
  type        = number
  default     = 150
}

variable "worker_vm_boot_size" {
  description = "worker-vm boot volume GB"
  type        = number
  default     = 50
}

# 네트워크
variable "vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}
