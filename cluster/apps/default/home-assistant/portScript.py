start_port = 30001
end_port = 30051
ports = range(start_port, end_port + 1)

with open("voice-assistant-ports.yaml", "w") as file:
  file.write('''apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: home-assistant
  namespace: default
spec:
  values:
    service:
      voice-assistant:
        type: NodePort
        ports:''')
  for port in ports:
    file.write(f'''
          np-udp-{port}:
            port: {port}
            targetPort: {port}
            nodePort: {port}
            protocol: UDP''')
