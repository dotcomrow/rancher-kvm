################################################################################
# ENV VARS
################################################################################

## Gloabl

variable "K8S_VERSION" {
  default = "v1.31.3+rke2r1"
  type    = string
}

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
  default = 1
  type    = number
}

variable "SRVR_NODE_VCPU" {
  default = 4
  type    = number
}

variable "SRVR_NODE_MEMORY" {
  default = "16384"
  type    = string
}

variable "SRVR_VM_IMG_SIZE" {
  default =  100 * 1024 * 1024 * 1024 # 100GiB.
  type    = string
}

## ETCD Nodes

variable "ETCD_NODE_HOSTNAME" {
  default = "etcd-node"
  type    = string
}

variable "ETCD_NODE_COUNT" {
  default = 1
  type    = number
}

variable "ETCD_NODE_VCPU" {
  default = 4
  type    = number
}

variable "ETCD_NODE_MEMORY" {
  default = "32768"
  type    = string
}

variable "ETCD_VM_IMG_SIZE" {
  default = 500 * 1024 * 1024 * 1024 # 500GiB.
  type    = string
}


## Controlplane Nodes

variable "CTRL_NODE_HOSTNAME" {
  default = "ctrl-node"
  type    = string
}

variable "CTRL_NODE_COUNT" {
  default = 1
  type    = number
}

variable "CTRL_NODE_VCPU" {
  default = 4
  type    = number
}

variable "CTRL_NODE_MEMORY" {
  default = "49152"
  type    = string
}

variable "CTRL_VM_IMG_SIZE" {
  default = 500 * 1024 * 1024 * 1024 # 500GiB.
  type    = string
}

## Worker Nodes

variable "WORK_NODE_HOSTNAME" {
  default = "work-node"
  type    = string
}

variable "WORK_NODE_COUNT" {
  default = 1
  type    = number
}

variable "WORK_NODE_VCPU" {
  default = 28
  type    = number
}

variable "WORK_NODE_MEMORY" {
  default = "393216"
  type    = string
}

variable "WORK_VM_IMG_SIZE" {
  default = 1800 * 1024 * 1024 * 1024 # 1800GiB.
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
data "template_file" "user_data_srvr" {
  count = var.SRVR_NODE_COUNT
  template = file("${path.module}/cloud_init_srvr.cfg")
  vars = {
    VM_USER = var.VM_USER
    HOSTNAME = format("${var.SRVR_NODE_HOSTNAME}-%02s", count.index)
    K8S_VERSION = var.K8S_VERSION
  }
}

data "template_file" "user_data_work" {
  count = var.WORK_NODE_COUNT
  template = file("${path.module}/cloud_init_work.cfg")
  vars = {
    VM_USER = var.VM_USER
    HOSTNAME = format("${var.WORK_NODE_HOSTNAME}-%02s", count.index)
    K8S_VERSION = var.K8S_VERSION
  }
}

data "template_file" "user_data_etcd" {
  count = var.ETCD_NODE_COUNT
  template = file("${path.module}/cloud_init_etcd.cfg")
  vars = {
    VM_USER = var.VM_USER
    HOSTNAME = format("${var.ETCD_NODE_HOSTNAME}-%02s", count.index)
    K8S_VERSION = var.K8S_VERSION
  }
}

data "template_file" "user_data_ctrl" {
  count = var.CTRL_NODE_COUNT
  template = file("${path.module}/cloud_init_ctrl.cfg")
  vars = {
    VM_USER = var.VM_USER
    HOSTNAME = format("${var.CTRL_NODE_HOSTNAME}-%02s", count.index)
    K8S_VERSION = var.K8S_VERSION
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

resource "libvirt_cloudinit_disk" "cloudinit_srvr" {
  count            = var.SRVR_NODE_COUNT
  name             = "${var.VM_CLUSTER}_cloudinit_srvr_${count.index}.iso"
  user_data        = element(data.template_file.user_data_srvr.*.rendered, count.index)
  network_config   = data.template_file.network_config.rendered
  pool             = libvirt_pool.vm.name
}

resource "libvirt_cloudinit_disk" "cloudinit_etcd" {
  count            = var.ETCD_NODE_COUNT
  name             = "${var.VM_CLUSTER}_cloudinit_etcd_${count.index}.iso"
  user_data        = element(data.template_file.user_data_etcd.*.rendered, count.index)
  network_config   = data.template_file.network_config.rendered
  pool             = libvirt_pool.vm.name
}

resource "libvirt_cloudinit_disk" "cloudinit_work" {
  count            = var.WORK_NODE_COUNT
  name             = "${var.VM_CLUSTER}_cloudinit_work_${count.index}.iso"
  user_data        = element(data.template_file.user_data_work.*.rendered, count.index)
  network_config   = data.template_file.network_config.rendered
  pool             = libvirt_pool.vm.name
}

resource "libvirt_cloudinit_disk" "cloudinit_ctrl" {
  count            = var.CTRL_NODE_COUNT
  name             = "${var.VM_CLUSTER}_cloudinit_ctrl_${count.index}.iso"
  user_data        = element(data.template_file.user_data_ctrl.*.rendered, count.index)
  network_config   = data.template_file.network_config.rendered
  pool             = libvirt_pool.vm.name
}

resource "libvirt_volume" "os_image_ubuntu" {
  name   = "os_image_ubuntu"
  pool   = libvirt_pool.vm.name
  source = "${var.VM_IMG_PATH}"
}


## SRVR Node

resource "libvirt_volume" "srvr_node" {
  count  = var.SRVR_NODE_COUNT
  name   = format("${var.VM_CLUSTER}-${var.SRVR_NODE_HOSTNAME}-%02s_volume.${var.VM_IMG_FORMAT}", count.index)
  pool   = libvirt_pool.vm.name
  base_volume_id = libvirt_volume.os_image_ubuntu.id
  format = var.VM_IMG_FORMAT
  size   = var.SRVR_VM_IMG_SIZE
}

resource "libvirt_domain" "srvr_node" {
  count      = var.SRVR_NODE_COUNT
  name       = format("${var.SRVR_NODE_HOSTNAME}-%02s", count.index)
  memory     = var.SRVR_NODE_MEMORY
  vcpu       = var.SRVR_NODE_VCPU
  autostart  = true
  qemu_agent = false

  cloudinit = libvirt_cloudinit_disk.cloudinit_srvr[count.index].id

  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_id = libvirt_network.vm_public_network.id
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
  base_volume_id = libvirt_volume.os_image_ubuntu.id
  format = var.VM_IMG_FORMAT
  size   = var.ETCD_VM_IMG_SIZE
}

resource "libvirt_domain" "etcd_node" {
  count      = var.ETCD_NODE_COUNT
  name       = format("${var.ETCD_NODE_HOSTNAME}-%02s", count.index)
  memory     = var.ETCD_NODE_MEMORY
  vcpu       = var.ETCD_NODE_VCPU
  autostart  = true
  qemu_agent = false

  cloudinit = libvirt_cloudinit_disk.cloudinit_etcd[count.index].id

  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_id = libvirt_network.vm_public_network.id
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
  base_volume_id = libvirt_volume.os_image_ubuntu.id
  format = var.VM_IMG_FORMAT
  size   = var.CTRL_VM_IMG_SIZE
}

resource "libvirt_domain" "ctrl_node" {
  count      = var.CTRL_NODE_COUNT
  name       = format("${var.CTRL_NODE_HOSTNAME}-%02s", count.index)
  memory     = var.CTRL_NODE_MEMORY
  vcpu       = var.CTRL_NODE_VCPU
  autostart  = true
  qemu_agent = false

  cloudinit = libvirt_cloudinit_disk.cloudinit_ctrl[count.index].id

  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_id = libvirt_network.vm_public_network.id
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
  base_volume_id = libvirt_volume.os_image_ubuntu.id
  format = var.VM_IMG_FORMAT
  size   = var.WORK_VM_IMG_SIZE
}

resource "libvirt_domain" "work_node" {
  count      = var.WORK_NODE_COUNT
  name       = format("${var.WORK_NODE_HOSTNAME}-%02s", count.index)
  memory     = var.WORK_NODE_MEMORY
  vcpu       = var.WORK_NODE_VCPU
  autostart  = true
  qemu_agent = false

  cloudinit = libvirt_cloudinit_disk.cloudinit_work[count.index].id

  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_id = libvirt_network.vm_public_network.id
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