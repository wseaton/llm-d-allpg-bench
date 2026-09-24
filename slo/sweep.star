scenario(
    stages = [stage("45s", mode="poisson", rate=r, name="r%d" % r) for r in [8, 16, 24, 32, 40, 48]],
    workload = workload("synthetic", isl=256, osl=128, headers={"x-llm-d-inference-objective": "live"}),
)
