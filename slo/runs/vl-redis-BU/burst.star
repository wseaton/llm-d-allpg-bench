scenario(
    stages = [stage("120s", mode="poisson", rate=15)],
    workload = workload("synthetic", isl=256, osl=128, headers={"x-llm-d-inference-objective": "live"}),
)
