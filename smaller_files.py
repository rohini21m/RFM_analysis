# splitting a huge file into smaller chunks to load into snowflake. 


import pandas as pd 
chunk_size=275039
batch_no=1
for chunk in pd.read_csv("path/fact_transactions",chunksize = chunk_size): 
    chunk.to_csv('fact_transactions' + str(batch_no) + '.csv', index=False) 
    batch_no+=1 


# snowflake : create tables,user_stage-> user_stage->copy_into command 

