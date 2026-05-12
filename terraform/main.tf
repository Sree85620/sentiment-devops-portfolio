###############################################################################
# main.tf — Local Portfolio Project: AI Sentiment API on Minikube
# Senior Cloud Architect / Lead DevOps QA | UK Market
#
# NETWORKING OVERVIEW
# ─────────────────────────────────────────────────────────────────────────────
# Ubuntu Host (bare-metal / VM)
#   └─► Minikube VM / node (bridge network, default: 192.168.49.0/24)
#         └─► Kubernetes cluster
#               └─► Pod: deepaiorg/sentiment-analysis (container port 5000)
#                     └─► Service: NodePort
#                           containerPort : 5000   (inside the pod)
#                           targetPort    : 5000   (pod → service)
#                           nodePort      : 30005  (Minikube node → host)
#
# Access from Ubuntu host:
#   curl http://$(minikube ip):30005/
#   — OR (after `minikube tunnel`) —
#   curl http://localhost:30005/
#
# minikube tunnel creates a loopback route so NodePort traffic on the Ubuntu
# host's lo interface at port 30005 is forwarded into the Minikube node.
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    # kubernetes provider talks to whichever cluster kubeconfig points at.
    # For Minikube: run `minikube start` first; kubeconfig is auto-merged.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    # helm is included for optional future Prometheus/ArgoCD bootstrap.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
}

###############################################################################
# Provider: read kubeconfig from the local Minikube context
###############################################################################
provider "kubernetes" {
  # Minikube writes its context to ~/.kube/config automatically.
  # Override KUBECONFIG env-var or path if using K3s:
  #   config_path = "/etc/rancher/k3s/k3s.yaml"
  config_path    = "~/.kube/config"
  config_context = "minikube" # change to "default" for K3s
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "minikube"
  }
}

###############################################################################
# Variables
###############################################################################
variable "namespace" {
  description = "Kubernetes namespace for the sentiment workload"
  type        = string
  default     = "sentiment"
}

variable "app_name" {
  description = "Application label used across all resources"
  type        = string
  default     = "sentiment-api"
}

variable "image" {
  description = "Docker image for the sentiment analysis service"
  type        = string
  default     = "deepaiorg/sentiment-analysis:latest"
}

variable "container_port" {
  description = "Port the container listens on internally"
  type        = number
  default     = 5000
}

variable "node_port" {
  description = "NodePort exposed on the Minikube node (accessible from Ubuntu host via minikube tunnel)"
  type        = number
  default     = 30005
}

variable "replicas" {
  description = "Number of pod replicas"
  type        = number
  default     = 2
}

###############################################################################
# Namespace
###############################################################################
resource "kubernetes_namespace" "sentiment" {
  metadata {
    name = var.namespace
    labels = {
      "managed-by"  = "terraform"
      "environment" = "local-dev"
      "project"     = "sentiment-portfolio"
    }
  }
}

###############################################################################
# Deployment
# ─────────────────────────────────────────────────────────────────────────────
# The DeepAI sentiment container exposes HTTP on port 5000.
# We set resource limits appropriate for a local dev machine (adjust for RAM).
###############################################################################
resource "kubernetes_deployment" "sentiment_api" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace.sentiment.metadata[0].name
    labels = {
      app         = var.app_name
      version     = "v1"
      "managed-by" = "terraform"
    }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        app = var.app_name
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }

    template {
      metadata {
        labels = {
          app     = var.app_name
          version = "v1"
        }
        # Prometheus scrape annotations (matches Prometheus config in observability/)
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = tostring(var.container_port)
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        # Never pull if already cached locally — speeds up Minikube cold starts.
        # Change to "Always" in staging/prod.
        container {
          name              = var.app_name
          image             = var.image
          image_pull_policy = "IfNotPresent"

          port {
            # containerPort: the port the process inside the container listens on.
            # This does NOT expose it outside the pod by itself; the Service does.
            container_port = var.container_port
            protocol       = "TCP"
            name           = "http"
          }

          # ── Resource limits (tune for your laptop RAM) ──────────────────
          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          # ── Liveness / Readiness probes ─────────────────────────────────
          liveness_probe {
            http_get {
              path = "/"
              port = var.container_port
            }
            initial_delay_seconds = 15
            period_seconds        = 20
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/"
              port = var.container_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          # ── Environment variables ────────────────────────────────────────
          env {
            name  = "ENVIRONMENT"
            value = "local-dev"
          }
        }

        # Graceful shutdown window
        termination_grace_period_seconds = 30
      }
    }
  }

  depends_on = [kubernetes_namespace.sentiment]
}

###############################################################################
# Service — NodePort
# ─────────────────────────────────────────────────────────────────────────────
# Traffic flow:
#   Ubuntu host:30005
#     → Minikube node eth0:30005   (NodePort range 30000-32767)
#       → ClusterIP (kube-proxy iptables DNAT)
#         → Pod:5000               (containerPort)
#
# To reach from the Ubuntu host without knowing the Minikube IP:
#   1. Run `minikube tunnel` in a separate terminal (needs sudo for iptables)
#   2. Then curl http://localhost:30005/
###############################################################################
resource "kubernetes_service" "sentiment_api" {
  metadata {
    name      = "${var.app_name}-svc"
    namespace = kubernetes_namespace.sentiment.metadata[0].name
    labels = {
      app          = var.app_name
      "managed-by" = "terraform"
    }
  }

  spec {
    selector = {
      app = var.app_name
    }

    type = "NodePort"

    port {
      name        = "http"
      port        = 80          # ClusterIP port (internal cluster traffic)
      target_port = var.container_port  # Pod's containerPort (5000)
      node_port   = var.node_port       # Exposed on Minikube node → Ubuntu host
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_deployment.sentiment_api]
}

###############################################################################
# Outputs — printed after `terraform apply`
###############################################################################
output "access_instructions" {
  description = "How to reach the Sentiment API from your Ubuntu host"
  value = <<-EOT
    ┌─────────────────────────────────────────────────────────────┐
    │  Sentiment API — Local Access                               │
    ├─────────────────────────────────────────────────────────────┤
    │  Option A (direct Minikube IP):                             │
    │    MINIKUBE_IP=$(minikube ip)                               │
    │    curl http://$MINIKUBE_IP:${var.node_port}/               │
    │                                                             │
    │  Option B (localhost via tunnel):                           │
    │    sudo minikube tunnel   # keep running in another term    │
    │    curl http://localhost:${var.node_port}/                  │
    │                                                             │
    │  Namespace : ${var.namespace}                                      │
    │  Service   : ${var.app_name}-svc                                 │
    │  NodePort  : ${var.node_port}                                      │
    └─────────────────────────────────────────────────────────────┘
  EOT
}

output "service_name" {
  value = kubernetes_service.sentiment_api.metadata[0].name
}

output "namespace" {
  value = kubernetes_namespace.sentiment.metadata[0].name
}
