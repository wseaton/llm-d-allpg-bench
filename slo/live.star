scenario(
    stages = [stage("LIVE_SECONDS", mode="poisson", rate=LIVE_RATE)],
    workload = workload("synthetic", isl=256, osl=128, headers={"x-llm-d-inference-objective": "live"}),
)
