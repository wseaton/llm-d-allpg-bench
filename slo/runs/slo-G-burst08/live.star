# 60 s at the base rate, 60 s near pool capacity, 60 s back at the base rate.
scenario(
    stages = [
        stage("60s", mode="poisson", rate=16),
        stage("60s", mode="poisson", rate=28),
        stage("60s", mode="poisson", rate=16),
    ],
    workload = workload("synthetic", isl=256, osl=128, headers={"x-llm-d-inference-objective": "live"}),
)
