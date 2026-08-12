apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: __ACM_CERTIFICATE_ARN__
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    # ArgoCD's own server already terminates TLS internally by default and
    # expects to speak gRPC/HTTPS to its backend — this tells the ALB to
    # talk HTTPS to the pod too, not plain HTTP, avoiding a protocol
    # mismatch that otherwise shows up as the UI loading but API/CLI calls
    # failing.
    alb.ingress.kubernetes.io/backend-protocol: HTTP

spec:
  ingressClassName: alb

  rules:
    - host: __ARGOCD_HOSTNAME__
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
