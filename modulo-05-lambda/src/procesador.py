# Procesador de mensajes SQS
import json

def handler(event, context):
    """Procesa mensajes de una cola SQS."""
    resultados = []
    
    for record in event.get("Records", []):
        body = json.loads(record.get("body", "{}"))
        print(f"Procesando mensaje: {body}")
        resultados.append({
            "message_id": record.get("messageId"),
            "procesado": True,
            "contenido": body,
        })
    
    return {
        "statusCode": 200,
        "body": json.dumps({
            "mensajes_procesados": len(resultados),
            "resultados": resultados,
        })
    }
