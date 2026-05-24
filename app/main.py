from prometheus_client import Counter, Histogram, generate_latest
from fastapi.responses import Response
import time
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import time
import random
import os

app = FastAPI(title="Shadow Payment Service")
request_count = Counter(
    'payment_requests_total',
    'Total payment requests',
    ['version', 'status']
)

request_duration = Histogram(
    'payment_duration_seconds',
    'Payment request duration',
    ['version']
)

error_count = Counter(
    'payment_errors_total',
    'Total payment errors',
    ['version', 'error_type']
)
VERSION = os.getenv("VERSION", "v1")

class PaymentRequest(BaseModel):
    amount: float
    currency: str = "USD"
    source: str = "Shepherd"

@app.get("/")
def root():
    return {
        "service": "Shadow Payment Gateway",
        "version": VERSION,
        "status": "operational"
    }

@app.get("/health")
def health():
    return {
        "status": "healthy",
        "version": VERSION
    }

@app.post("/pay")
def process_payment(payment: PaymentRequest):

    start_time = time.time()

    try:
        transaction_id = f"TXN-{random.randint(100000, 999999)}"

        response = {
            "status": "success",
            "transaction_id": transaction_id,
            "amount": payment.amount,
            "currency": payment.currency,
            "source": payment.source,
            "version": VERSION,
            "build": f"{VERSION}-canary",
            "message": f"Payment from {payment.source} processed successfully"
        }

        request_count.labels(
            version=VERSION,
            status='success'
        ).inc()

        return response

    except Exception as e:

        request_count.labels(
            version=VERSION,
            status='error'
        ).inc()

        error_count.labels(
            version=VERSION,
            error_type=type(e).__name__
        ).inc()

        raise

    finally:

        duration = time.time() - start_time

        request_duration.labels(
            version=VERSION
        ).observe(duration)
 # Simulate payment processing
       
@app.get("/fail")
def trigger_failure():

    error_count.labels(
        version=VERSION,
        error_type="simulated_failure"
    ).inc()

    raise HTTPException(
        status_code=500,
        detail="Simulated failure for chaos testing"
    )

@app.get("/slow")
def slow_endpoint():
    """Latency injection endpoint - 2 second delay"""
    time.sleep(2)

    return {
        "status": "completed",
        "message": "This endpoint intentionally delays 2 seconds",
        "version": VERSION
    }
@app.get("/metrics")
def metrics():
    return Response(
        content=generate_latest(),
        media_type="text/plain"
    )

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
