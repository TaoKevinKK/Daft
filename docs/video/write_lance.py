import os
import ray
import daft
import pyarrow as pa

from daft.functions import file
from fusionflowkit import get_oss_spark_config

RAY_CLUSTER_ADDRESS = "ray://xxx:10001"
ray.shutdown()
ray.init(
    address=RAY_CLUSTER_ADDRESS,
    runtime_env={"pip": ["daft", "pillow", "s3fs", "av", "pylance"]},
)

daft.context.set_runner_ray(RAY_CLUSTER_ADDRESS)

video_dir = "xxx"

raw_file_paths = []
for root, _, files in os.walk(video_dir):
    for f in files:
        if f.endswith(".mp4"):
            raw_file_paths.append({"path": os.path.join(root, f)})


@daft.func
def read_videos(file: daft.File) -> bytes:
    return file.read()


@daft.func
def get_size(file: daft.File) -> int:
    return len(file.read())


df = daft.from_pylist(raw_file_paths)
df = df.select("path", get_size(file(df["path"])).alias("size"), read_videos(file(df["path"])).alias("videos"))

schema = pa.schema(
    [
        pa.field("path", pa.string()),  # 视频路径
        pa.field("size", pa.int64()),  # 视频大小
        pa.field(
            "videos",
            pa.large_binary(),
            metadata={"lance-encoding:blob": "true"}  # Lance 二进制标记
        ),
    ]
)

dynamic_config = daft.io.IOConfig(
    s3=daft.io.S3Config(
    )
)

lance_dataset_path = "",
df.write_lance(lance_dataset_path, schema=daft.schema.Schema.from_pyarrow_schema(schema), io_config=dynamic_config)
