resource "kubernetes_namespace" "stage" {
  metadata {
    name = "stage"
  }
  
  depends_on = [
    google_container_node_pool.primary_nodes
  ]
}

resource "kubernetes_namespace" "prod" {
  metadata {
    name = "prod"
  }

  depends_on = [
    google_container_node_pool.primary_nodes
  ]
}