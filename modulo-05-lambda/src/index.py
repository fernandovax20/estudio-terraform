# Lambda handler de ejemplo para Terraform Lab
import json

def handler(event, context):
    """Función Lambda de ejemplo desplegada con Terraform."""
    print(f"Evento recibido: {json.dumps(event)}")
    
    return {
        "statusCode": 200,
        "body": json.dumps({
            "mensaje": "¡Hola desde Lambda desplegada con Terraform!",
            "evento_recibido": event,
            "funcion": context.function_name if context else "local",
        })
    }
