Create a polished landscape infographic for a "Stackable Data Platform on AKS" overview.

Goal:
- Show every Stackable operator currently used in this platform.
- For each operator, show its primary function in one short line.
- Make the image useful as an architecture overview for engineers and stakeholders.

Style:
- Modern technical infographic
- Clean, premium, presentation-ready
- Light background with subtle depth and gradients
- Crisp typography, distinct section colors, minimal iconography
- High legibility, not cartoonish, not cluttered
- 16:9 layout

Content structure:

Title:
- Stackable Data Platform on AKS

Subtitle:
- Operators and their role in the platform

Group the operators into clear sections with cards:

1. Platform Foundations
- Commons Operator: shared building blocks and common platform APIs
- Secret Operator: manages TLS materials and credentials for workloads
- Listener Operator: exposes service listeners and connection endpoints
- ZooKeeper Operator: coordination and quorum for distributed services

2. Storage and Data Services
- HDFS Operator: distributed file storage for the platform
- HBase Operator: low-latency NoSQL storage
- Hive Operator: metastore and table metadata services
- OpenSearch Operator: search and log analytics engine

3. Streaming and Ingestion
- Kafka Operator: durable event streaming backbone
- NiFi Operator: flow-based ingestion, routing, and ETL

4. Processing and Analytics
- Spark K8s Operator: distributed Spark jobs on Kubernetes
- Trino Operator: federated SQL query engine
- Druid Operator: real-time OLAP and time-series analytics
- Airflow Operator: workflow orchestration and scheduling
- Superset Operator: BI dashboards and interactive analytics
- OPA Operator: policy enforcement and authorization for data access

Optional callout:
- Stackable Cockpit: platform UI for operations and visibility

Layout guidance:
- Show section blocks from foundation to analytics
- Use short arrows or subtle connectors to suggest data flow from ingestion to storage to analytics
- Keep each operator in its own labeled card
- Each card should contain:
  - operator name
  - one concise function line

Text requirements:
- Use the operator names exactly as written above
- Keep descriptions concise and verb-oriented
- No extra operators
- No marketing slogans

Avoid:
- Dark, heavy backgrounds
- Generic cloud clip art
- Overly abstract shapes that reduce readability
- Dense paragraphs
- Tiny labels

Output:
- A single PNG infographic suitable for docs, slide decks, or README usage
