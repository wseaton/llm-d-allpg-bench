scenario(
    stages = [stage("300s", mode="poisson", rate=110)],
    workload = workload("synthetic", isl=256, osl=128, headers={"x-llm-d-inference-objective": "live"}),
)
