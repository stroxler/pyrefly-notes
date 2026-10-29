---- MODULE RawDynamicGraph ----

\* Node mapping (alias -> Alloy atom):
\* n0 = Node$0
\* n1 = Node$1
\* n2 = Node$2
\* n3 = Node$3

Nodes == {"n0", "n1", "n2", "n3"}

StepCount == 4

FullGraph ==
[n \in Nodes |->
    IF n = "n0" THEN {"n0", "n2"}
    ELSE IF n = "n1" THEN {"n0", "n1"}
    ELSE IF n = "n2" THEN {"n1"}
    ELSE {}
]

Step0 ==
[n \in Nodes |->
    IF n = "n0" THEN {"n2"}
    ELSE IF n = "n1" THEN {"n0", "n1"}
    ELSE IF n = "n2" THEN {"n1"}
    ELSE {}
]

Step1 ==
[n \in Nodes |->
    IF n = "n0" THEN {"n0", "n2"}
    ELSE IF n = "n1" THEN {"n0", "n1"}
    ELSE IF n = "n2" THEN {"n1"}
    ELSE {}
]

Step2 ==
[n \in Nodes |->
    IF n = "n0" THEN {"n0", "n2"}
    ELSE IF n = "n1" THEN {"n0", "n1"}
    ELSE IF n = "n2" THEN {"n1"}
    ELSE {}
]

Step3 ==
[n \in Nodes |->
    IF n = "n0" THEN {"n2"}
    ELSE IF n = "n1" THEN {"n0", "n1"}
    ELSE IF n = "n2" THEN {"n1"}
    ELSE {}
]

DynamicSteps ==
    <<Step0, Step1, Step2, Step3>>

====
