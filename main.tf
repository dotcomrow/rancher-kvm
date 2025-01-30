################################################################################
# ENV VARS
################################################################################

## Gloabl

variable "VM_USER" {
  default = "rancher"
  type    = string
}

variable "VM_IMG_PATH" {
  default = "/home/chris/isos/ubuntu-24.04-server-cloudimg-amd64.img"
  type    = string
}

variable "VM_IMG_DIR" {
  default = "/var/lib/libvirt/images"
  type    = string
}

variable "VM_IMG_FORMAT" {
  default = "qcow2"
  type    = string
}

variable "VM_BRIDGE" {
  default = "br0"
  type    = string
}

variable "VM_CIDR_RANGE" {
  default = "192.168.10.1/24"
  type    = string
}

variable "VM_CLUSTER" {
  default = "rancher"
  type    = string
}

## Server Nodes

variable "SRVR_NODE_HOSTNAME" {
  default = "srvr-node"
  type    = string
}

variable "SRVR_NODE_COUNT" {
  default = 3
  type    = number
}

variable "SRVR_NODE_VCPU" {
  default = 1
  type    = number
}

variable "SRVR_NODE_MEMORY" {
  default = "2048"
  type    = string
}

## ETCD Nodes

variable "ETCD_NODE_HOSTNAME" {
  default = "etcd-node"
  type    = string
}

variable "ETCD_NODE_COUNT" {
  default = 3
  type    = number
}

variable "ETCD_NODE_VCPU" {
  default = 2
  type    = number
}

variable "ETCD_NODE_MEMORY" {
  default = "6144"
  type    = string
}

## Controlplane Nodes

variable "CTRL_NODE_HOSTNAME" {
  default = "ctrl-node"
  type    = string
}

variable "CTRL_NODE_COUNT" {
  default = 2
  type    = number
}

variable "CTRL_NODE_VCPU" {
  default = 1
  type    = number
}

variable "CTRL_NODE_MEMORY" {
  default = "2048"
  type    = string
}

## Worker Nodes

variable "WORK_NODE_HOSTNAME" {
  default = "work-node"
  type    = string
}

variable "WORK_NODE_COUNT" {
  default = 3
  type    = number
}

variable "WORK_NODE_VCPU" {
  default = 4
  type    = number
}

variable "WORK_NODE_MEMORY" {
  default = "24576"
  type    = string
}

################################################################################
# PROVIDERS
################################################################################

# instance the provider
provider "libvirt" {
  uri = "qemu:///system"
}

################################################################################
# DATA TEMPLATES
################################################################################

# https://www.terraform.io/docs/providers/template/d/file.html

# https://www.terraform.io/docs/providers/template/d/cloudinit_config.html
data "template_file" "user_data" {
  template = file("${path.module}/cloud_init.cfg")
  vars = {
    VM_USER = var.VM_USER
  }
}

data "template_file" "network_config" {
  template = file("${path.module}/network_config.cfg")
}

################################################################################
# RESOURCES
################################################################################

resource "libvirt_pool" "vm" {
  name = "${var.VM_CLUSTER}_pool"
  type = "dir"
  target {
    path = var.VM_IMG_DIR
  }
}

resource "libvirt_network" "vm_public_network" {
  name   = "${var.VM_CLUSTER}_network"
  mode   = "bridge"
  bridge = var.VM_BRIDGE

  addresses = ["${var.VM_CIDR_RANGE}"]
  autostart = true
  dhcp {
    enabled = true
  }
  dns {
    enabled = true
  }
}

resource "libvirt_cloudinit_disk" "cloudinit" {
  name             = "${var.VM_CLUSTER}_cloudinit.iso"
  user_data        = data.template_file.user_data.rendered
  network_config   = data.template_file.network_config.rendered
  pool             = libvirt_pool.vm.name
}

## SRVR Node

resource "libvirt_volume" "srvr_node" {
  count  = var.SRVR_NODE_COUNT
  name   = format("${var.VM_CLUSTER}-${var.SRVR_NODE_HOSTNAME}-%02s_volume.${var.VM_IMG_FORMAT}", count.index)
  pool   = libvirt_pool.vm.name
  source = var.VM_IMG_PATH
  format = var.VM_IMG_FORMAT
}

resource "libvirt_domain" "srvr_node" {
  count      = var.SRVR_NODE_COUNT
  name       = format("${var.SRVR_NODE_HOSTNAME}-%02s", count.index)
  memory     = var.SRVR_NODE_MEMORY
  vcpu       = var.SRVR_NODE_VCPU
  autostart  = true
  qemu_agent = true

  cloudinit = libvirt_cloudinit_disk.cloudinit.id

  network_interface {
    network_id = libvirt_network.vm_public_network.id
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  console {
    type        = "pty"
    target_type = "virtio"
    target_port = "1"
  }

  disk {
    volume_id = libvirt_volume.srvr_node[count.index].id
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }
}

## ETCD Node

resource "libvirt_volume" "etcd_node" {
  count  = var.ETCD_NODE_COUNT
  name   = format("${var.VM_CLUSTER}-${var.ETCD_NODE_HOSTNAME}-%02s_volume.${var.VM_IMG_FORMAT}", count.index)
  pool   = libvirt_pool.vm.name
  source = var.VM_IMG_PATH
  format = var.VM_IMG_FORMAT
}

resource "libvirt_domain" "etcd_node" {
  count      = var.ETCD_NODE_COUNT
  name       = format("${var.ETCD_NODE_HOSTNAME}-%02s", count.index)
  memory     = var.ETCD_NODE_MEMORY
  vcpu       = var.ETCD_NODE_VCPU
  autostart  = true
  qemu_agent = true

  cloudinit = libvirt_cloudinit_disk.cloudinit.id

  network_interface {
    network_id = libvirt_network.vm_public_network.id
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  console {
    type        = "pty"
    target_type = "virtio"
    target_port = "1"
  }

  disk {
    volume_id = libvirt_volume.etcd_node[count.index].id
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }
}

## CTRL Node

resource "libvirt_volume" "ctrl_node" {
  count  = var.CTRL_NODE_COUNT
  name   = format("${var.VM_CLUSTER}-${var.CTRL_NODE_HOSTNAME}-%02s_volume.${var.VM_IMG_FORMAT}", count.index)
  pool   = libvirt_pool.vm.name
  source = var.VM_IMG_PATH
  format = var.VM_IMG_FORMAT
}

resource "libvirt_domain" "ctrl_node" {
  count      = var.CTRL_NODE_COUNT
  name       = format("${var.CTRL_NODE_HOSTNAME}-%02s", count.index)
  memory     = var.CTRL_NODE_MEMORY
  vcpu       = var.CTRL_NODE_VCPU
  autostart  = true
  qemu_agent = true

  cloudinit = libvirt_cloudinit_disk.cloudinit.id

  network_interface {
    network_id = libvirt_network.vm_public_network.id
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  console {
    type        = "pty"
    target_type = "virtio"
    target_port = "1"
  }

  disk {
    volume_id = libvirt_volume.ctrl_node[count.index].id
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }
}

## WORK Node

resource "libvirt_volume" "work_node" {
  count  = var.WORK_NODE_COUNT
  name   = format("${var.VM_CLUSTER}-${var.WORK_NODE_HOSTNAME}-%02s_volume.${var.VM_IMG_FORMAT}", count.index)
  pool   = libvirt_pool.vm.name
  source = var.VM_IMG_PATH
  format = var.VM_IMG_FORMAT
}

resource "libvirt_domain" "work_node" {
  count      = var.WORK_NODE_COUNT
  name       = format("${var.WORK_NODE_HOSTNAME}-%02s", count.index)
  memory     = var.WORK_NODE_MEMORY
  vcpu       = var.WORK_NODE_VCPU
  autostart  = true
  qemu_agent = true

  cloudinit = libvirt_cloudinit_disk.cloudinit.id

  network_interface {
    network_id = libvirt_network.vm_public_network.id
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  console {
    type        = "pty"
    target_type = "virtio"
    target_port = "1"
  }

  disk {
    volume_id = libvirt_volume.work_node[count.index].id
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }
}

################################################################################
# TERRAFORM CONFIG
################################################################################

terraform {
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
    }
  }
}

terraform {
  required_version = ">= 0.12"
}