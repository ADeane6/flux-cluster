.PHONEY: logs-minecraft
logs-minecraft:
    kubectl logs -n games -l app=minecraft-paper-minecraft -c minecraft-paper-minecraft -f
