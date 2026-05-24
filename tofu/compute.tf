resource "oci_core_instance" "ops_vm" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.availability_domain
  display_name        = "ops-vm"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  source_details {
    source_type             = "image"
    source_id               = local.image_id
    boot_volume_size_in_gbs = var.ops_vm_boot_size
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = false
    nsg_ids          = [oci_core_network_security_group.ops.id]
    hostname_label   = "ops-vm"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}

resource "oci_core_instance" "worker_vm" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.availability_domain
  display_name        = "worker-vm"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  source_details {
    source_type             = "image"
    source_id               = local.image_id
    boot_volume_size_in_gbs = var.worker_vm_boot_size
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.private.id
    assign_public_ip = false
    nsg_ids          = [oci_core_network_security_group.worker.id]
    hostname_label   = "worker-vm"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}

# Reserved Public IP → ops-vm primary VNIC attach
data "oci_core_vnic_attachments" "ops_vm_vnics" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.availability_domain
  instance_id         = oci_core_instance.ops_vm.id
}

data "oci_core_private_ips" "ops_vm_private_ips" {
  vnic_id = data.oci_core_vnic_attachments.ops_vm_vnics.vnic_attachments[0].vnic_id
}

resource "oci_core_public_ip" "ops_reserved" {
  compartment_id = var.compartment_ocid
  display_name   = "ops-vm-reserved-ip"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.ops_vm_private_ips.private_ips[0].id
}
