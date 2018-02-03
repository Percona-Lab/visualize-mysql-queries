This is a command line tool to visualize queries in performance_schema. 
The approach is similar to mlogvis tool for MongoDB - it creats static html file using d3 javascipt lib.

Run the visualize.sh script on a server (similar to pcs-collect-enviroment.sh), it will connect to MySQL and pre-generate 3 json files 
(from  events_statements_summary_by_digest table). Then it will archive the files, but also run python -m SimpleHTTPServer to serve files from the server
