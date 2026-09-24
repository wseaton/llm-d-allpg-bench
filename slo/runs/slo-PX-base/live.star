scenario(
    stages = [stage("420s", mode="poisson", rate=80)],
    workload = workload("synthetic", isl=256, osl=128, headers={"x-llm-d-inference-objective": "live"}),
)
