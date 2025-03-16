from fastapi import FastAPI, HTTPException
import os

app = FastAPI()

ENV_VAR_NAME = "RADARBOX_KEY"

@app.get(f"/{ENV_VAR_NAME}")
async def get_env_variable():
    value = os.getenv(ENV_VAR_NAME)
    
    if value is None:
        raise HTTPException(status_code=404, detail=f"{ENV_VAR_NAME} not set")

    return {ENV_VAR_NAME: value}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=32088)