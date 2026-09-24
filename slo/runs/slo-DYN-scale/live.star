scenario(
    stages = [stage("600s", mode="poisson", rate=60)],
    workload = workload("synthetic", isl=256, osl=128, headers={"x-llm-d-inference-objective": "live"}),
)
