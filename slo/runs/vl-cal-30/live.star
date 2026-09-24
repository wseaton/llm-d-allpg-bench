scenario(
    stages = [stage("180s", mode="poisson", rate=30)],
    workload = workload("synthetic", isl=256, osl=128, headers={"x-llm-d-inference-objective": "live"}),
)
