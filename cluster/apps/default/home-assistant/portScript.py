start_port = 10400
end_port = 10450
ports = range(start_port, end_port + 1)

with open("load-balancer.yaml", "w") as file:
  file.write('''apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: home-assistant
  namespace: default
spec:
  values:
    service:
      lb:
        type: LoadBalancer
        loadBalancerIP: "${HASS_LB}"
        externalTrafficPolicy: Local
        ports:
          http-lb:
            enabled: true
            port: 8123
            protocol: HTTP
          hue-lb:
            port: 80''')
  for port in ports:
    file.write(f'''
          udp-{port}:
            port: {port}
            protocol: UDP''')
