# Clicky Fork's prepared test Mac: one layer on Cirrus's sequoia base image, in the layered style of
# cirruslabs/macos-image-templates.
packer {
  required_plugins {
    tart = { version = ">= 1.21.0", source = "github.com/cirruslabs/tart" }
  }
}

variable "vm_name" { type = string }
# The FluidAudio Parakeet v3 model folder on the host, staged into the guest so the app needs no download.
# FluidAudio 0.18 loads v3 from `parakeet-tdt-0.6b-v3` (with JointDecisionv3.mlmodelc), not the older `-coreml` folder.
variable "model_dir" {
  type    = string
  default = "${env("HOME")}/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
}

source "tart-cli" "golden" {
  vm_base_name   = "ghcr.io/cirruslabs/macos-sequoia-base:latest"
  vm_name        = var.vm_name
  cpu_count      = 4
  memory_gb      = 8
  headless       = true
  ssh_username   = "admin"
  ssh_password   = "admin"
  ssh_timeout    = "180s"
  run_extra_args = ["--no-audio"]
}

build {
  sources = ["source.tart-cli.golden"]

  # Files made on the host at build time; `generated = true` skips Packer's up-front existence check.
  provisioner "shell-local" {
    inline = ["bash clips/make-clips.sh build/clips", "bash driver/build.sh build/driver", "bash provision/fetch-blackhole.sh build/blackhole", "bash provision/fetch-audio-tools.sh build/brew-cache"]
  }
  provisioner "shell" {
    inline = [
      "mkdir -p /Users/admin/clips /Users/admin/standin /Users/admin/testenv-driver /Users/admin/fixture-vault /Users/admin/fixture-brain /Users/admin/blackhole /Users/admin/brew-cache /Users/admin/model-staging",
      "mkdir -p '/Users/admin/Library/Application Support/FluidAudio/Models'",
    ]
  }
  provisioner "file" {
    source      = "build/clips/"
    destination = "/Users/admin/clips/"
    generated   = true
  }
  provisioner "file" {
    source      = "build/driver/clicky-driver"
    destination = "/Users/admin/testenv-driver/clicky-driver"
    generated   = true
  }
  provisioner "file" {
    source      = "build/blackhole/"
    destination = "/Users/admin/blackhole/"
    generated   = true
  }
  provisioner "file" {
    source      = "build/brew-cache/"
    destination = "/Users/admin/brew-cache/"
    generated   = true
  }
  # scp rejects a destination with a space, so stage the model first and move it in.
  provisioner "file" {
    source      = var.model_dir
    destination = "/Users/admin/model-staging/"
  }
  provisioner "shell" {
    inline = ["mv /Users/admin/model-staging/* '/Users/admin/Library/Application Support/FluidAudio/Models/' && rmdir /Users/admin/model-staging"]
  }
  # The stand-ins (claude-standin/claude, codex-standin/codex): canned answers, no login, no network.
  provisioner "file" {
    source      = "claude-standin/claude"
    destination = "/Users/admin/standin/claude"
  }
  provisioner "file" {
    source      = "codex-standin/codex"
    destination = "/Users/admin/standin/codex"
  }
  provisioner "file" {
    source      = "fixture-vault/"
    destination = "/Users/admin/fixture-vault/"
  }
  provisioner "file" {
    source      = "fixture-brain/"
    destination = "/Users/admin/fixture-brain/"
  }
  provisioner "file" {
    source      = "launch-app.sh"
    destination = "/Users/admin/launch-app.sh"
  }
  provisioner "file" {
    source      = "reset-walk.sh"
    destination = "/Users/admin/reset-walk.sh"
  }
  provisioner "shell" {
    script = "provision/fixtures.sh"
  }
  provisioner "shell" {
    script = "provision/audio.sh"
  }
  provisioner "shell" {
    script = "provision/tcc.sh"
  }
}
