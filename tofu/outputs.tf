output "ops_vm_public_ip" {
  description = "ops-vm reserved public IP — 외부 DNS A 레코드 대상"
  value       = oci_core_public_ip.ops_reserved.ip_address
}

output "ops_vm_id" {
  description = "ops-vm OCID"
  value       = oci_core_instance.ops_vm.id
}

output "worker_vm_id" {
  description = "worker-vm OCID"
  value       = oci_core_instance.worker_vm.id
}

output "vcn_id" {
  value = oci_core_vcn.main.id
}

output "ops_nsg_id" {
  value = oci_core_network_security_group.ops.id
}

output "worker_nsg_id" {
  value = oci_core_network_security_group.worker.id
}
