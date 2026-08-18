from setuptools import setup, find_packages

setup(
    name="checkmate",
    version="0.2.0",
    packages=find_packages(),
    scripts=[
        "job_monitoring/check_hang.py",
        "job_monitoring/check_nan.py",
        "utils/get_healthy_nodes.sh",
        "utils/gemm_diagnose.sh",
        "utils/node_memory_report.sh",
        "utils/overalloc.sh",
        "utils/node_usage_summary.sh",
        "utils/launcher.sh",
        "utils/flush.sh",
        "system_monitoring/run_health_checks.py",
        "system_monitoring/dashboard.py",
    ],
    author="Huihuo Zheng",
    author_email="huihuo.zheng@anl.gov",
    description=("Resilient Job Continuation with Checkpoint/Restart and Node-Health Tooling at Exascale."),
    long_description=open("README.md").read(),
    long_description_content_type="text/markdown",
    url="https://github.com/argonne-lcf/checkmate",
    classifiers=[
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: MIT License",
        "Operating System :: OS Independent",
    ],
    install_requires=[
        "PyYAML>=6.0",
    ],
    python_requires=">=3.6",
)
